# serialfd
This is a set of programs emulate a floppy drive on DOS over a serial port.

The DOS part 'serialfd.asm' is written in x86 assembly and runs as a DOS TSR program loaded in the background. It will intercept BIOS int 13h calls, forward these over the serial port and wait for the response.

The counterpart 'serialfd.c' is written in C and created to run on Linux. This part will load a floppy disk image and operate on sectors from it based on calls received on the serial port.

There is also 'sfdboot.asm' which is a bootloader stub to load bootable floppy disk images.

