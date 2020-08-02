org 0x0 ; Position independent.
bits 16
cpu 8086

COM1_BASE equ 0x3f8
COM1_THR  equ COM1_BASE + 0 ; Transmitter Holding Buffer
COM1_RBR  equ COM1_BASE + 0 ; Receiver Buffer
COM1_IER  equ COM1_BASE + 1 ; Interrupt Enable Register
COM1_FCR  equ COM1_BASE + 2 ; FIFO Control Register
COM1_IIR  equ COM1_BASE + 2 ; Interrupt Identification Register
COM1_LCR  equ COM1_BASE + 3 ; Line Control Register
COM1_LSR  equ COM1_BASE + 5 ; Line Status Register
COM1_DLL  equ COM1_BASE + 0 ; Divisor Latch Low Byte
COM1_DLH  equ COM1_BASE + 1 ; Divisor Latch High Byte

RESIDENT_SEGMENT equ 0x0030 ; Bootstrap stack area.

section .text
start:
  jmp main

resident_code_start:
  ; Setup ES:BX to point at bootloader address 07C0:0
  mov ax, 0x07C0
  mov es, ax
  xor bx, bx

  ; Read VBR into bootloader memory area:
  mov ax, 0x0201
  mov cx, 0x0001
  xor dx, dx
  int 0x13

  ; Jump to bootloader:
  jmp 0x0:0x7C00

int13_interrupt:
  ; Allow other interrupts:
  sti

  ; Check if accessing drive 0 (A:)
  ; If not, then jump to original interrupt instead.
  cmp dl, 0
  jne original_int13

  ; Only operation 0x02 (Read) and 0x03 (Write) are forwarded.
  ; The rest are bypassed directly and returns OK.
  cmp ah, 2
  je _int13_interrupt_ah_ok
  cmp ah, 3
  jne _int13_interrupt_end
_int13_interrupt_ah_ok:

  ; Save registers:
  push bx
  push cx
  push dx

  ; Save sectors and operation information on stack for use later:
  push ax
  push ax
  push ax

  ; Register AL already set.
  call com_port_send
  mov al, ah
  call com_port_send
  mov al, cl
  call com_port_send
  mov al, ch
  call com_port_send
  mov al, dl
  call com_port_send
  mov al, dh
  call com_port_send

  ; Retrieve sector information (stack AL) into DL register:
  pop dx
  xor dh, dh

  mov ax, 512
  mul dx ; DX:AX = AX * DX
  mov cx, ax

  ; Determine receive (Read) or send (Write) from operation (stack AH):
  pop ax
  cmp ah, 3
  je _int13_interrupt_send_loop

_int13_interrupt_recv_loop:
  call com_port_recv
  mov [es:bx], al
  inc bx
  loop _int13_interrupt_recv_loop
  jmp _int13_loop_done

_int13_interrupt_send_loop:
  mov al, [es:bx]
  call com_port_send
  inc bx
  loop _int13_interrupt_send_loop

_int13_loop_done:

  ; Retrieve sector information (stack AL) as sectors handled:
  pop ax

  ; Restore registers:
  pop dx
  pop cx
  pop bx

_int13_interrupt_end:
  ; AL register will have same value as upon entering routine.
  xor ah, ah ; Code 0 (No Error)
  clc ; Clear error bit.
  retf 2

original_int13:
  jmp original_int13:original_int13 ; Will be overwritten runtime!

; Send contents from AL on COM1 port:
com_port_send:
  push dx
  mov dx, COM1_THR
  out dx, al
  mov dx, COM1_LSR
_com_port_send_wait:
  in al, dx
  and al, 0b00100000 ; Empty Transmit Holding Register
  test al, al
  jz _com_port_send_wait
  pop dx
  ret

; Return contents in AL on COM1 port:
com_port_recv:
  push dx
_com_port_recv_wait:
  mov dx, COM1_IIR
  in al, dx
  and al, 0b00001110 ; Identification
  cmp al, 0b00000100 ; Enable Received Data Available Interrupt
  jne _com_port_recv_wait
  mov dx, COM1_RBR
  in al, dx
  pop dx
  ret

resident_code_end:

main:
  ; Set Baudrate on COM1 to 9600, divisor = 12:
  mov dx, COM1_LCR
  in al, dx
  or al, 0b10000000 ; Set Divisor Latch Access Bit (DLAB).
  out dx, al

  mov dx, COM1_DLL
  mov al, 0xc
  out dx, al
  
  mov dx, COM1_DLH
  mov al, 0
  out dx, al

  mov dx, COM1_LCR
  in al, dx
  and al, 0b01111111 ; Reset Divisor Latch Access Bit (DLAB).
  out dx, al

  ; Disable and clear FIFO on COM1, to put it in 8250 compatibility mode:
  mov dx, COM1_FCR
  mov al, 0b00000110 ; Clear both FIFOs.
  out dx, al
  ; NOTE: Not tested what happens if this is run on an actual 8250 chip...

  ; Set mode on COM1 to 8 data bits, no parity and 1 stop bit:
  mov dx, COM1_LCR
  mov al, 0b00000011 ; 8-N-1
  out dx, al

  ; Enable interrupt bit on COM1:
  mov dx, COM1_IER
  in al, dx
  or al, 0b00000001 ; Enable Received Data Available Interrupt
  out dx, al

  ; Interact directly with IVT:
  xor ax, ax
  mov ds, ax ; Data Segment now 0000
  cli ; Disable Interrupts

  call get_ip
get_ip:
  pop ax ; IP
  pop bx ; CS
  sub ax, (get_ip - resident_code_start)
  mov si, ax ; "resident_code_start" now in SI.

  ; Copy the code to a new resident area using CS:SI -> ES:DI
  mov ax, RESIDENT_SEGMENT
  mov es, ax
  mov di, 0
  mov cx, (resident_code_end - resident_code_start)
_copy_to_resident_area:
  mov byte al, [cs:si]
  mov byte [es:di], al
  inc si
  inc di
  loop _copy_to_resident_area

  ; Save old interrupt handler:
  ; ES = RESIDENT_SEGMENT
  mov ax, [ds:0x4c]
  mov word [es:original_int13 - resident_code_start + 1], ax
  mov ax, [ds:0x4e]
  mov word [es:original_int13 - resident_code_start + 3], ax

  ; Overwrite with new interrupt handler:
  ; ES = RESIDENT_SEGMENT
  mov word [ds:0x4c], (int13_interrupt - resident_code_start)
  mov word [ds:0x4e], es

  ; Zero out COM1 port address in BDA to avoid DOS interference:
  ; DOS can set baudrate to 2400 at startup, which will cause issues.
  xor ax, ax
  mov word [ds:0x400], ax

  sti ; Enable Interrupts

  ; Indicate on screen "Ready for Loading" after key press:
  mov ah, 0x9  ; Write character and attribute at cursor position.
  mov al, 0x21 ; Character = '!'
  mov bh, 0    ; Page Number = 0
  mov bl, 0x4  ; Color = Red
  mov cx, 0x3  ; Number of Times = 3
  int 0x10

  ; Read any key press:
  mov ah, 0x0  ; Read keystroke.
  int 0x16

  ; Jump to new resident area:
  jmp RESIDENT_SEGMENT:0

