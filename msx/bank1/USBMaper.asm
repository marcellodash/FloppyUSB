HW_IMPL_GET_DEV_DESCR: equ 1
HW_IMPL_GET_CONFIG_DESCR: equ 1
HW_IMPL_SET_CONFIG: equ 1
HW_IMPL_SET_ADDRESS: equ 1
HW_IMPL_CONFIGURE_NAK_RETRY: equ 1

; -----------------------------------------------------------------------------
; Mandatory routines
; -----------------------------------------------------------------------------

; -----------------------------------------------------------------------------
; HW_TEST: Check if the USB host controller hardware is operational
; -----------------------------------------------------------------------------
; Output: Cy = 0 if hardware is operational, 1 if it's not

HW_TEST:
    ld a,34h
    call _HW_TEST_DO
    scf
    ret nz

    ld a,89h
    call _HW_TEST_DO
    scf
    ret nz

    or a
    ret

_HW_TEST_DO:
    ld b,a
    ld a,CH_CMD_CHECK_EXIST
    out (CH_COMMAND_PORT),a
    ld a,b
    xor 0FFh
    out (CH_DATA_PORT),a
    in a,(CH_DATA_PORT)
    cp b
    ret


; -----------------------------------------------------------------------------
; HW_RESET: Reset the USB controller hardware
;
; If a device is connected performs a bus reset that leaves the device
; in the "Default" state.
; -----------------------------------------------------------------------------
; Input:  -
; Output: A = 1 if a USB device is connected
;             -1 if no USB device is connected
;         Cy = 1 if reset failed

HW_RESET:

    ;Clear the CH376 data buffer in case a reset was made
    ;while it was in the middle of a data transfer operation
    ;ld b,64
_HW_RESET_CLEAR_DATA_BUF:
    in a,(CH_DATA_PORT)
    djnz _HW_RESET_CLEAR_DATA_BUF

    ld a,CH_CMD_RESET_ALL
    out (CH_COMMAND_PORT),a

    if USING_ARDUINO_BOARD=1
    ld bc,1000
_HW_RESET_WAIT:
    dec bc
    ld a,b
    or c
    jr nz,_HW_RESET_WAIT
    else
    ld bc,350
    call CH_DELAY
    endif

    call CH_DO_SET_NOSOF_MODE
    ret c

    ld a,CH_CMD_TEST_CONNECT
    out (CH_COMMAND_PORT),a
_CH_WAIT_TEST_CONNECT:
    in a,(CH_DATA_PORT)
    or a
    jr z,_CH_WAIT_TEST_CONNECT
    cp CH_ST_INT_DISCONNECT
    ld a,-1
    ret z

    jp HW_BUS_RESET


; -----------------------------------------------------------------------------
; HW_DEV_CHANGE: Check for changes in the device connection
;
; The returned status is relative to the last time that the routine
; was called.
;
; If a device has been connected it performs a bus reset that leaves the device
; in the "Default" state.
; -----------------------------------------------------------------------------
; Input:  -
; Output: A = 1 if a USB device has been connected
;             0 if no change has been detected
;             -1 if the USB device has been disconnected
;         Cy = 1 if bus reset failed

HW_DEV_CHANGE:
    call CH_CHECK_INT_IS_ACTIVE
    ld a,0
    ret nz

    call CH_GET_STATUS
    cp CH_ST_INT_CONNECT
    jp z,HW_BUS_RESET
    cp CH_ST_INT_DISCONNECT
    jp z,CH_DO_SET_NOSOF_MODE

    xor a
    ret


; -----------------------------------------------------------------------------
; HW_CONTROL_TRANSFER: Perform a USB control transfer on endpoint 0
;
; The size and direction of the transfer are taken from the contents
; of the setup packet.
; -----------------------------------------------------------------------------
; Input:  HL = Address of a 8 byte buffer with the setup packet
;         DE = Address of the input or output data buffer
;         A  = Device address
;         B  = Maximum packet size for endpoint 0
; Output: A  = USB error code
;         BC = Amount of data actually transferred (if IN transfer and no error)

HW_CONTROL_TRANSFER:
    call CH_SET_TARGET_DEVICE_ADDRESS

    push hl
    push bc
    push de

    ld b,8
    call CH_WRITE_DATA  ;Write SETUP data packet

    xor a
    ld e,0
    ld b,CH_PID_SETUP
    call CH_ISSUE_TOKEN

    call CH_WAIT_INT_AND_GET_RESULT
    pop hl  ;HL = Data address (was DE)
    pop de  ;D  = Endpoint size (was B)
    pop ix  ;IX = Address of setup packet (was HL)
    or a
    ld bc,0
    ret nz  ;DONE if error

    ld c,(ix+6)
    ld b,(ix+7) ;BC = Data length
    ld a,b
    or c
    jr z,_CH_CONTROL_STATUS_IN_TRANSFER
    ld e,0      ;E  = Endpoint number
    scf         ;Use toggle = 1
    bit 7,(ix)
    jr z,_CH_CONTROL_OUT_TRANSFER

_CH_CONTROL_IN_TRANSFER:
    call CH_DATA_IN_TRANSFER
    or a
    ret nz

    push bc

    ld b,0
    call CH_WRITE_DATA
    ld e,0
    ld b,CH_PID_OUT
    ld a,40h    ;Toggle bit = 1
    call CH_ISSUE_TOKEN
    call CH_WAIT_INT_AND_GET_RESULT

    pop bc
    ret

_CH_CONTROL_OUT_TRANSFER:
    call CH_DATA_OUT_TRANSFER
    or a
    ret nz

_CH_CONTROL_STATUS_IN_TRANSFER:
    push bc

    ld e,0
    ld b,CH_PID_IN
    ld a,80h    ;Toggle bit = 1
    call CH_ISSUE_TOKEN
    ld hl,0
    call CH_READ_DATA
    call CH_WAIT_INT_AND_GET_RESULT

    pop bc
    ret


; -----------------------------------------------------------------------------
; HW_DATA_IN_TRANSFER: Perform a USB data IN transfer
; -----------------------------------------------------------------------------
; Input:  HL = Address of a buffer for the received data
;         BC = Data length
;         A  = Device address
;         D  = Maximum packet size for the endpoint
;         E  = Endpoint number
;         Cy = Current state of the toggle bit
; Output: A  = USB error code
;         BC = Amount of data actually received (only if no error)
;         Cy = New state of the toggle bit (even on error)

HW_DATA_IN_TRANSFER:
    call CH_SET_TARGET_DEVICE_ADDRESS

; This entry point is used when target device address is already set
CH_DATA_IN_TRANSFER:
    ld a,0
    rra     ;Toggle to bit 7 of A
    ld ix,0 ;IX = Received so far count
    push de
    pop iy  ;IY = EP size + EP number

_CH_DATA_IN_LOOP:
    push af ;Toggle in bit 7
    push bc ;Remaining length

    ld e,iyl
    ld b,CH_PID_IN
    call CH_ISSUE_TOKEN

    call CH_WAIT_INT_AND_GET_RESULT
    or a
    jr nz,_CH_DATA_IN_ERR   ;DONE if error

    call CH_READ_DATA
    ld b,0
    add ix,bc   ;Update received so far count
_CH_DATA_IN_NO_MORE_DATA:

    pop de
    pop af
    xor 80h     ;Update toggle
    push af
    push de

    ld a,c
    or a
    jr z,_CH_DATA_IN_DONE    ;DONE if no data received

    ex (sp),hl  ;Now HL = Remaining data length
    or a
    sbc hl,bc   ;Now HL = Updated remaning data length
    ld a,h
    or l
    ex (sp),hl  ;Remaining data length is back on the stack
    jr z,_CH_DATA_IN_DONE    ;DONE if no data remaining

    ld a,c
    cp iyh
    jr c,_CH_DATA_IN_DONE    ;DONE if transferred less than the EP size

    pop bc
    pop af  ;We need this to pass the next toggle to CH_ISSUE_TOKEN

    jr _CH_DATA_IN_LOOP

;Input: A=Error code (if ERR), in stack: remaining length, new toggle
_CH_DATA_IN_DONE:
    xor a
_CH_DATA_IN_ERR:
    ld d,a
    pop bc
    pop af
    rla ;Toggle back to Cy
    ld a,d
    push ix
    pop bc
    ret


; -----------------------------------------------------------------------------
; HW_DATA_OUT_TRANSFER: Perform a USB data OUT transfer
; -----------------------------------------------------------------------------
; Input:  HL = Address of a buffer for the data to be sent
;         BC = Data length
;         A  = Device address
;         D  = Maximum packet size for the endpoint
;         E  = Endpoint number
;         Cy = Current state of the toggle bit
; Output: A  = USB error code
;         Cy = New state of the toggle bit (even on error)

HW_DATA_OUT_TRANSFER:
    call CH_SET_TARGET_DEVICE_ADDRESS

; This entry point is used when target device address is already set
CH_DATA_OUT_TRANSFER:
    ld a,0
    rra     ;Toggle to bit 6 of A
    rra
    push de
    pop iy  ;IY = EP size + EP number

_CH_DATA_OUT_LOOP:
    push af ;Toggle in bit 6
    push bc ;Remaining length

    ld a,b
    or a
    ld a,iyh
    jr nz,_CH_DATA_OUT_DO
    ld a,c
    cp iyh
    jr c,_CH_DATA_OUT_DO
    ld a,iyh

_CH_DATA_OUT_DO:
    ;Here, A = Length of the next transfer: min(remaining length, EP size)

    ex (sp),hl
    ld e,a
    ld d,0
    or a
    sbc hl,de
    ex (sp),hl     ;Updated remaining data length to the stack

    ld b,a
    call CH_WRITE_DATA

    pop bc
    pop af  ;Retrieve toggle
    push af
    push bc

    ld e,iyl
    ld b,CH_PID_OUT
    call CH_ISSUE_TOKEN

    call CH_WAIT_INT_AND_GET_RESULT
    or a
    jr nz,_CH_DATA_OUT_DONE   ;DONE if error

    pop bc
    pop af
    xor 40h     ;Update toggle
    push af

    ld a,b
    or c
    jr z,_CH_DATA_OUT_DONE_2  ;DONE if no more data to transfer

    pop af  ;We need this to pass the next toggle to CH_ISSUE_TOKEN

    jr _CH_DATA_OUT_LOOP

;Input: A=Error code, in stack: remaining length, new toggle
_CH_DATA_OUT_DONE:
    pop bc
_CH_DATA_OUT_DONE_2:
    ld d,a
    pop af
    rla ;Toggle back to Cy
    rla
    ld a,d
    ret


; -----------------------------------------------------------------------------
; HW_BUS_RESET: Performs a USB bus reset.
;
; This needs to run when a device connection is detected.
; -----------------------------------------------------------------------------
; Output: A  = 1
;         Cy = 1 on error

HW_BUS_RESET:
    ld a,7
    call CH_SET_USB_MODE
    ld a,1
    ret c

    if USING_ARDUINO_BOARD = 0
    ld bc,150
    call CH_DELAY
    endif

    ld a,6
    call CH_SET_USB_MODE

    ld a,1
    ret c

    xor a
    inc a
    ret

    ;Input: BC = Delay duration in units of 0.1ms
CH_DELAY:
    ld a,CH_CMD_DELAY_100US
    out (CH_COMMAND_PORT),a
_CH_DELAY_LOOP:
    in a,(CH_DATA_PORT)
    or a
    jr z,_CH_DELAY_LOOP
    dec bc
    ld a,b
    or c
    jr nz,CH_DELAY
    ret


; -----------------------------------------------------------------------------
; Optional shortcut routines
; -----------------------------------------------------------------------------

; -----------------------------------------------------------------------------
; HW_GET_DEV_DESCR and HW_GET_CONFIG_DESCR
;
; Exectute the standard GET_DESCRIPTOR USB request
; to obtain the device descriptor or the configuration descriptor.
; -----------------------------------------------------------------------------
; Input:  DE = Address where the descriptor is to be read
;         A  = Device address
; Output: A  = USB error code

    if HW_IMPL_GET_DEV_DESCR = 1

HW_GET_DEV_DESCR:
    ld b,1
    jr CH_GET_DESCR

    endif

    if HW_IMPL_GET_CONFIG_DESCR = 1

HW_GET_CONFIG_DESCR:
    ld b,2
    jr CH_GET_DESCR

    endif

    if HW_IMPL_GET_DEV_DESCR = 1 or HW_IMPL_GET_CONFIG_DESCR = 1

CH_GET_DESCR:
    push bc
    call CH_SET_TARGET_DEVICE_ADDRESS

    ld a,CH_CMD_GET_DESCR
    out (CH_COMMAND_PORT),a
    pop af
    out (CH_DATA_PORT),a

    push de
    call CH_WAIT_INT_AND_GET_RESULT
    pop hl
    or a
    ret nz

    call CH_READ_DATA
    ld b,0
    xor a
    ret

    endif


; -----------------------------------------------------------------------------
; HW_SET_ADDRESS
;
; Exectute the standard SET_CONFIGURATION USB request.
; -----------------------------------------------------------------------------
; Input: A = Device address
;        B = Configuration number to assign

    if HW_IMPL_SET_CONFIG = 1

    ;In: A=Address, B=Config number
HW_SET_CONFIG:
    call CH_SET_TARGET_DEVICE_ADDRESS
    ld a,CH_CMD_SET_CONFIG
    out (CH_COMMAND_PORT),a
    ld a,b
    out (CH_DATA_PORT),a

    call CH_WAIT_INT_AND_GET_RESULT
    ret

    endif


; -----------------------------------------------------------------------------
; HW_SET_ADDRESS
;
; Exectute the standard SET_ADDRESS USB request.
; -----------------------------------------------------------------------------
; Input: A = Adress to assign

    if HW_IMPL_SET_ADDRESS = 1

HW_SET_ADDRESS:
    push af
    xor a
    call CH_SET_TARGET_DEVICE_ADDRESS
    ld a,CH_CMD_SET_ADDRESS
    out (CH_COMMAND_PORT),a
    pop af
    out (CH_DATA_PORT),a

    call CH_WAIT_INT_AND_GET_RESULT
    ret

    endif


; -----------------------------------------------------------------------------
; HW_CONFIGURE_NAK_RETRY
; -----------------------------------------------------------------------------
; Input: Cy = 0 to retry for a limited time when the device returns NAK
;               (this is the default)
;             1 to retry indefinitely (or for a long time)
;               when the device returns NAK

HW_CONFIGURE_NAK_RETRY:
    ld a,0FFh
    jr nc,_HW_CONFIGURE_NAK_RETRY_2
    ld a,0BFh
_HW_CONFIGURE_NAK_RETRY_2:
    push af
    ld a,CH_CMD_SET_RETRY
    out (CH_COMMAND_PORT),a
    ld a,25h    ;Fixed value, required by CH376
    out (CH_DATA_PORT),a

    ;Bits 7 and 6:
    ;  0x: Don't retry NAKs
    ;  10: Retry NAKs indefinitely (default)
    ;  11: Retry NAKs for 3s
    ;Bits 5-0: Number of retries after device timeout
    ;Default after reset and SET_USB_MODE is 8Fh
    pop af
    out (CH_DATA_PORT),a
    ret
