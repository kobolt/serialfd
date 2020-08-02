
all: serialfd serialfd.com sfdboot.bin

serialfd: serialfd.c
	gcc -o serialfd serialfd.c -Wall

serialfd.com: serialfd.asm
	nasm serialfd.asm -fbin -o serialfd.com

sfdboot.bin: sfdboot.asm
	nasm sfdboot.asm -fbin -o sfdboot.bin

.PHONY: clean
clean:
	rm -f serialfd.com serialfd sfdboot.bin

