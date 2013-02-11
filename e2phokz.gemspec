Gem::Specification.new do |gem|
  gem.name        = 'e2phokz'
  gem.summary     = "dump ext2/ext3 filesystem with skipping unused blocks (output them as zeroes)"
  gem.description = gem.summary
  gem.authors     = ["Josef Liska"]
  gem.email       = 'josef.liska@virtualmaster.com'
  gem.homepage    = "https://github.com/phokz/e2phokz"

  gem.add_development_dependency "rspec"
  gem.files         = `git ls-files`.split("\n")
  gem.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  gem.version       = File.open('VERSION').read.strip
  gem.add_dependency "stomp", "~> 1.2.8"
end
