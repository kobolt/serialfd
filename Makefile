
all: serialfd serialfd.com

serialfd: serialfd.c
	gcc -o serialfd serialfd.c -Wall

serialfd.com: serialfd.asm
	nasm serialfd.asm -fbin -o serialfd.com

.PHONY: clean
clean:
	rm -f serialfd.com serialfd

