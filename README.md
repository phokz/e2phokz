e2phokz
=======

dump ext2/ext3 filesystem with skipping unused blocks (output them as zeroes).


This is what is used to create minified and compressed virtualmaster images.
Prior to this approach, we used following two scenarios:

a) make a new blockdevice or image file of same size and copy relevant data with tar or rsync
Drawback was changing disk uuid.


b) mount image, fill the free space with big file full of zeroes, sync,
remove file and unmount.

This way was too slow

I know there exists probably a more suitable tool called partimage,
but we wanted two simple features: output to pipe and progress bar to
other channel (stomp in this case).



