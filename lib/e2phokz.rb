# e2phokz: script which copies and optionally compresses ext2/ext3 filesystem
# it only copies used block, instead of free blocks it writes zeros
#
# usage:
# e2phokz block_device_or_image_file output_file [stomp_channel_name]
#
# if output_file is suffixed with .gz, output will be compressed
# if output_file is -, output will be sent to stdout
# if optional stomp channel name is supplied, progress info will be sent
# there. Script reads /etc/e2phokz.yml to get server info and credential.

module E2Phokz
  CONFIG_FILENAME="/etc/e2phokz.yml"

  class App

    BUFFER_SIZE=16 #megabytes

    def initialize(options)
       @options = options
    end

    def buffercopy(infile,outfile,cls,s,e)

      bs = @fsinfo['block_size'].to_i
      num = (e-s+1)*bs
      warn "#{cls} from block #{s} to #{e} number of bytes #{num}" unless @debug.nil?

      maxbuf = BUFFER_SIZE*1024*1024 #16M
      rest = num
      count = 0

      infile.seek(s*bs,IO::SEEK_SET)

      while rest > 0
        count = rest > maxbuf ? maxbuf : rest
        rest = rest - count

        a = Time.now.to_f
        outfile.write(infile.read(count))
        b = Time.now.to_f
        warn "#{count} bytes read in #{b-a} sec, #{count/(b-a)} bytes/s" unless @debug.nil?
        eta_continuous count
        GC.start
      end
    end

    def progress_bar progress
      t = progress.last
      i = progress.first.split('%').first.to_f

      h=(t/3600).to_i
      m=((t%3600)/60).to_i
      s=((t%60)*10).to_i/10.0
      bars=(40*i/100).ceil
      bbars=(1..bars).collect {'#'}.join
      spaces=40-bars
      bspaces=(1..spaces).collect {' '}.join
      sep = @debug.nil? ? "\r" : "\n"
      $stderr.write "ETA #{sprintf('%02d:%02d:%02.1f',h,m,s)} #{sprintf('%3d',i)}% [#{bbars}#{bspaces}] #{sep}"
    end

    def eta_continuous count
      elapsed=Time.now.to_f-@time_start
      @written = @written + count
      to_be_written = @fsinfo['block_count'].to_i * @fsinfo['block_size'].to_i
      progress = (1000.0*@written/to_be_written)/10
      # weighted average
      eta = elapsed/progress*100 - elapsed
      new_eta = (progress*eta + (100-progress)*@initial_eta)/100
      #TODO support for non-gzipped ETA calculation
      progress_stomp [sprintf("%.2f",progress)+'%',new_eta]
      progress_bar [progress.to_s+'%',new_eta]
    end

    def eta_initial
      #TODO support for non-gzipped ETA calculation

      #constants
      gzip_free=0.02
      gzip_data=0.09

      bs=@fsinfo['block_size'].to_i
      @megs_used=(@fsinfo['block_count'].to_i-@fsinfo['free_blocks'].to_i)*bs/1024/1024
      @megs_free=(@fsinfo['free_blocks'].to_i*bs/1024/1024)
      eta = @megs_used*gzip_data+@megs_free*gzip_free
      @written = 0
      @initial_eta = eta
      progress_stomp ['0%',eta]
      progress_bar ['0%',eta]
    end

    def progress_stomp progress
      unless @stomp_client.nil?
        @stomp_client.publish(@channel_name,progress.join(';'))
      end
    end

    def connect_stomp
      begin
        config=YAML::load(File.open(CONFIG_FILENAME))['stomp']
      rescue
        warn "Error: cannot load or parse stomp config #{CONFIG_FILENAME}" && exit
      end

      begin
        @stomp_client = Stomp::Client.new(config['user'], config['password'], config['server'], config['port'])
      rescue
        warn "Error: cannot connect to stomp server #{config['server']}" && exit
      end
    end

    def parse_args
      @time_start=Time.now.to_f

      if @options.length < 2 or @options.length > 3
        puts File.open(__FILE__).read.split("\n").collect{|l| l.gsub('# ','') unless l.match(/^# /).nil?}.compact.join("\n")
        exit
      end
      if @options.length == 3
        @channel_name = @options.last
        connect_stomp
      end

      #test for presence of in file || device
      begin
        warn "Warning: input file #{@options.first} is not a block device" unless File::Stat.new(@options.first).blockdev?
        @file=File.open(@options.first,'rb')
      rescue
        warn "Error: infile #{@options.first} cannot be open." && exit
      end

      #test for presence of out file
      begin
        if File::Stat.new(@options[1]).blockdev?
          warn "Error: I will not overwrite block device #{@options[1]}"
        else
          warn "Error: I will not overwrite output file #{@options[1]}"
        end
        exit
      rescue
        warn "OK"
      end

      if @options[1]=='-'
        # writing to stdout, no compression
        @gzip=IO.new(1,"w")
      else
        begin
          if @options[1].split('.').last == 'gz'
            #compression required
            @gzip=Zlib::GzipWriter.open(@options[1])
          else
            @gzip=File.open(@options[1],'wb')
          end
        rescue
          warn "Error: cannot open output file #{@options[1]} for writing."
        end
      end

      @devzero=File.open("/dev/zero",'rb')

    end

    def parse_dumpe2fs
      begin
        dump = File.popen("dumpe2fs #{@options.first}",'r').read.split("\n")
      rescue
        warn "Error: cannot execute dump2efs" && exit
      end

      header = 1
      @fsinfo={}
      group_number=0
      from=0
      to=0
      dump.each do |row|
        if row==''		# header ends with empty row
          header = 0
          #we have processed heade, so we can count ETA now
          eta_initial
          next
        end

        if header == 1
          #we are processing header to @fsinfo hash
          fields = row.split(':')
          varname = fields.shift.split(' ').join('_').downcase
          value = fields.join(':').strip
          @fsinfo.merge!({varname => value})
        else
          #we are processing group info
          fields = row.split(' ')
          if fields.first=='Group'
            group_number = fields[1].to_i
            from = fields[3].split('-').first.to_i
            to = fields[3].split('-').last.to_i
            warn "Processing group #{group_number} #{from} #{to}" unless @debug.nil?
          else
            # we are only interested in free blocks info as of now
            fields = row.split(':')
            name = fields.first.strip
            if name == 'Free blocks' then
              ranges = fields.last.strip.split(', ')
              if ranges.empty?
                #copy whole group
                warn "Full copy of group #{group_number}" unless @debug.nil?
                buffercopy(@file,@gzip,'copy', from,to)
              else
                #copy only non-free blocks
                warn "Partial copy of group #{group_number}" unless @debug.nil?
                pointer = from
                ranges.each do |range|
                  range_start=range.split('-').first.to_i
                  range_end=range.split('-').last.to_i
                  buffercopy(@file,@gzip,'copy',pointer,range_start-1)
                  buffercopy(@devzero,@gzip,'zero',range_start,range_end)
                  pointer=range_end+1
                end
                if to > pointer
                  warn "Remaining blocks from last free to end of group #{group_number}" unless @debug.nil?
                  buffercopy(@file,@gzip,'copy',pointer,to)
                end
              end
            end

          end
        end
      end

    end

    def close_files
      @file.close
      @gzip.close
      @devzero.close
    end


    def run!
      parse_args
      parse_dumpe2fs
      close_files
      warn "\n"
    end

  end

    def E2Phokz.config_file
      return if File.exists?(CONFIG_FILENAME)
      begin
        File.open(CONFIG_FILENAME,'w') do |f|
          f.puts("# sample config - you can just ignore this if you do not inted to use stomp")
          f.puts(E2Phokz.sample_config.to_yaml)
        end
        system("editor #{CONFIG_FILENAME}")
      rescue
        puts "I was not able to place sample config to #{CONFIG_FILENAME}."
        puts "Please do it yourself. Config is only needed for stomp."
        puts "If you do not intend to use stomp, you can just ignore this."
      end
    end

    def E2Phokz.sample_config
      {"stomp"=>{"server"=>"stompserver.domain.tld", "user"=>"username", "port"=>61613, "password"=>"secure_enough_password"}}
    end

  def E2Phokz.main(options)
     E2Phokz.config_file
     E2Phokz::App.new(options).run!
  end

end
