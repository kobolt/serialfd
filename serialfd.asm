org 0x100
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

section .text
start:
  jmp main

int13_interrupt:
  ; Allow other interrupts:
  sti

  ; Check if accessing drive 0 (A:) or drive 1 (B:)
  ; If not, then jump to original interrupt instead.
  cmp dl, 0
  je _int13_interrupt_dl_ok
  cmp dl, 1
  jne original_int13
_int13_interrupt_dl_ok:

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

; TSR end marker:
tsr_end:

main:
  ; NOTE: No protection to prevent TSR from being loaded twice or more!

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

  ; Call DOS to get original interrupt handler:
  mov al, 0x13
  mov ah, 0x35
  int 0x21
  mov word [original_int13 + 3], es
  mov word [original_int13 + 1], bx

  ; Call DOS to set interrupt handler:
  mov al, 0x13
  mov ah, 0x25
  ; DS is already same as CS, no need to change.
  mov dx, int13_interrupt
  int 0x21

  ; Terminate and Stay Resident:
  mov dx, tsr_end
  shr dx, 1
  shr dx, 1
  shr dx, 1
  shr dx, 1
  add dx, 0x11 ; Add 0x1 for remainder and 0x10 for PSP.
  mov ax, 0x3100
  int 0x21

