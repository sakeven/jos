#include <inc/mmu.h>

# Start the CPU: switch to 32-bit protected mode, jump into C.
# The BIOS loads this code from the first sector of the hard disk into
# memory at physical address 0x7c00 and starts executing in real mode
# with %cs=0 %ip=7c00.
// BIOS 从硬盘的第一个扇区加载这个代码到物理内存地址为 0x7c00 处。
// 这时 cs=0 ip=7c00 开始在实模式下执行。

// .set 设定常数, 与 c 里的宏定义一样。
// 段选择器的结构如下，共 2 字节，保存在段寄存器里刚好，而段描述有 8 个字节，这里用 index 做个映射：
// --------------------------------------------------------------
// |       index (13bite)     |   TI (1bite) |     RPL(2bite)   |
// --------------------------------------------------------------
// 所以 0x8 表示CS 段描述在 GDT 表中的序号位 1 ，0x10 表示 DS 段描述的位置在 2。
.set PROT_MODE_CSEG, 0x8         # kernel code segment selector
.set PROT_MODE_DSEG, 0x10        # kernel data segment selector
.set CR0_PE_ON,      0x1         # protected mode enable flag

// .globl symbol, 这里 symbol 可以使 ld 时可见，是全局符号，就像全局变量一样。
// 这样另一个代码段，可以直接使用 start 地址。
.globl start
start:
  // 在实模式下，CPU总是进行16位的跳转，即当它在解析跳转的目标时，总是读取内存中的16位的值作为跳转目标。
  // 为此，汇编器要配合CPU，产生这种用16位表示偏移量的代码。
  .code16                     # Assemble for 16-bit mode
  // 设置数据段地址时，需要 CLI，禁止中断。
  // 如果允许中断，可能只设置了部分数据段，就调到别处执行，导致错误。
  cli                         # Disable interrupts
  // CLD 与 STD 是用来操作方向标志位 DF（Direction Flag）。CLD 使 DF 复位，即 DF=0，STD 使 DF 置位，即 DF=1。用于串操作指令中。
  cld                         # String operations increment

  # Set up the important data segment registers (DS, ES, SS).
  // 设置重要数据段寄存器。
  // 在 at&t 汇编下，源地址在前，目标地址在后。
  xorw    %ax,%ax             # Segment number zero
  // movw    $0x10,%ax             # Segment number zero
  // ds 的值设置位 ax 保存的值，即 0。后面 es 和 ss 也是 0。
  movw    %ax,%ds             # -> Data Segment
  movw    %ax,%es             # -> Extra Segment
  movw    %ax,%ss             # -> Stack Segment

  # Enable A20:
  #   For backwards compatibility with the earliest PCs, physical
  #   address line 20 is tied low, so that addresses higher than
  #   1MB wrap around to zero by default.  This code undoes this.
  // 在实模式下的寻址方式是，segment:offset，即 segment<<4 + offset
  // 而 segment 和 offset 都占 4 字节。在旧处理器 8086/8088 的地址线有 20 条，只能访问到 FFFFF，共 1M 地址空间。
  // 后续的处理器 80286，已经有 24 位地址线，在实模式寻址方式下，最高能到 FFFF:FFFF，即 10FFEF。
  // 在旧处理器上由于少了4条线，只能被截断回，FFEF，这种现象称为 wraparound。
  // 为了兼容旧处理器，使实模式下，访问结果一致，在 80286 上，A20 这条地址线被默认置为 0。
  // 在之后进入保护模式下，要能够完全访问 24/24+ 位地址空间，需要手动打开 A20 gate，避免 A20 一直是 0。
seta20.1:
  // 对 0x64 端口进行读操作，会读取 Status Register 的内容。
  // 判断状态 2（0x2）位上是否为 1，如果 1 则表示输入缓冲满。
  // 写数据到 IO port 0x60 or IO port 0x64 是时，状态位 2 上必须是 0。
  inb     $0x64,%al               # Wait for not busy
  testb   $0x2,%al
  jnz     seta20.1

  // 准备写 Output 端口。随后通过 0x60 端口写入的字节，会被放置在 Output Port 中。
  movb    $0xd1,%al               # 0xd1 -> port 0x64
  outb    %al,$0x64

seta20.2:
  inb     $0x64,%al               # Wait for not busy
  testb   $0x2,%al
  jnz     seta20.2

  // 发送命令 0xDF 置 A20 gate 有效；送命令 0xDD 置 A20 gate 无效。
  movb    $0xdf,%al               # 0xdf -> port 0x60
  outb    %al,$0x60

  # Switch from real to protected mode, using a bootstrap GDT
  # and segment translation that makes virtual addresses 
  # identical to their physical addresses, so that the 
  # effective memory map does not change during the switch.
  // 载入全局描述符
  //  movw    $0x10,%ax             # Segment number zero
  // movw    %ax,%ds             # -> Data Segment
  lgdt    gdtdesc
  xorw    %ax,%ax             # Segment number zero
  movw    %ax,%ds             # -> Data Segment

  // 切换到保护模式。保护模式的标识是 cr0 寄存器的 PE 位为 1，设为 1 就算打开了。
  movl    %cr0, %eax
  orl     $CR0_PE_ON, %eax
  movl    %eax, %cr0
  
  # Jump to next instruction, but in 32-bit code segment.
  # Switches processor into 32-bit mode.
  // Long jump 会重新装载 cs 和 eip 寄存器。
  // ljmp 是能够修改 cs 的方式之一，还有 far call， far return，和 interrupt return 等方式。
  // 这里要进入 32 位模式，需要把 GDT 中 CS 描述符装载到 cs 寄存器中。
  // 查看 GDT 发现， cs 段的基地址位 0x0， ip 段的值为 $protcseg。所以
  // cs:ip = 0x0:$protcseg = $protcseg
  // 最开始讲过实模式下 cs=0x0，所以转换后 protcseg 地址是不变的，这样就能正确跳转到 protcseg 段，进入 32 位模式。
  ljmp    $PROT_MODE_CSEG, $protcseg

  .code32                     # Assemble for 32-bit mode
protcseg:
  # Set up the protected-mode data segment registers
  // 设置保护模式下数据段各个寄存器
  // 这些寄存器只有 2 个字节大小
  movw    $PROT_MODE_DSEG, %ax    # Our data segment selector
  movw    %ax, %ds                # -> DS: Data Segment
  movw    %ax, %es                # -> ES: Extra Segment
  movw    %ax, %fs                # -> FS
  movw    %ax, %gs                # -> GS
  movw    %ax, %ss                # -> SS: Stack Segment
  
  # Set up the stack pointer and call into C.
  // 设置栈指针，就是这个代码段的开始位置 $start。
  // 接着进入 bootmain C 代码。
  movl    $start, %esp
  call bootmain

  # If bootmain returns (it shouldn't), loop.
spin:
  jmp spin

# Bootstrap GDT
.p2align 2                                # force 4 byte alignment
// 全局描述符表，有 3 个描述符，分别是 NULL 段，代码段，数据段，依次排列。
// 每个段的描述，占 8 个字节，包含段的基地址，大小，和权限。
// 现在就能明白 PROT_MODE_CSEG 和 PROT_MODE_DSEG 的含义了。
gdt:
  SEG_NULL				# null seg
  SEG(STA_X|STA_R, 0x0, 0xffffffff)	# code seg
  SEG(STA_W, 0x0, 0xffffffff)	        # data seg

// 全局描述符表的描述，一个数据结构，包含表最后一个字节序号，和表的起始地址。
// 基本结构是：
// --------------------------------------------
// |  size (2 byte)  |      addr (4 byte)      |
// --------------------------------------------
gdtdesc:
  .word   0x17                            # sizeof(gdt) - 1
  .long   gdt                             # address gdt

