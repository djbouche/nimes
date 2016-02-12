import "../types", strutils, sequtils

const NSFMagic = 0x4D53454E

template writeByte(sequence: seq[uint8], counter: expr, value: uint8) =
  echo counter.int.toHex(4) & ": " & value.int.toHex(2)
  prg[counter-0x8000] = value
  counter.inc

template writeWord(sequence: seq[uint8], counter: int, value: uint16) =
  sequence.writeByte(counter, (value and 0xFF).uint8)
  sequence.writeByte(counter, (value shr 8).uint8)

template writeRelativeBranch(sequence: seq[uint8], counter: int, opcode: uint8, address: uint16) =
  sequence.writeByte(counter, opcode)
  let iOffset = address.int - (1 + counter.int)
  let offset: uint8 =
    if iOffset < 0:
      (iOffset + 0x100).uint8
    else:
      (iOffset).uint8
  sequence.writeByte(counter, offset)

template writeLdaImm(sequence: seq[uint8], counter: int, immediate: uint8) =
  # LDA #$xx
  sequence.writeByte(counter, 0xA9)
  sequence.writeByte(counter, immediate)

template writeStaAddr(sequence: seq[uint8], counter: int, address: uint16) =
  # STA $xxxx
  sequence.writeByte(counter, 0x8D)
  sequence.writeWord(counter, address)

template writeLdaImmStaAddr(sequence: seq[uint8], counter: int, immediate: uint8, address: uint16) =
  # LDA #$xx
  sequence.writeLdaImm(counter, immediate)
  # STA $xxxx
  sequence.writeStaAddr(counter, address)

template createLabel(counter: int, name: untyped) {.immediate.} =
  let name: uint16 = counter.uint16
  echo ""
  echo name.astToStr & ":"

type NSFHeader = object {.packed.}
  magic: uint32
  magic1A: uint8
  version, songCount, startingSongIndex: uint8
  loadAddr, initAddr, playAddr: uint16
  songName, artistName, copyrightName: array[32, uint8]
  playSpeedNTSC: uint16
  bankSwitchInit: array[8, uint8]
  playSpeedPAL: uint16
  regionBits: uint8
  soundChip: uint8
  padding: array[4, uint8]

proc readNSFFile*(cartridge: Cartridge, file: File, songNumber: int = 0) =
  var header: NSFHeader
  # Read directly into the header object
  if file.readBuffer(addr header, sizeof header) != sizeof header:
    raise newException(ValueError, "header can't be read")

  if header.magic != NSFMagic or header.magic1A != 0x1A:
    raise newException(ValueError, "header not conforming to NSF format")

  var bankSwitched = false
  for bank in header.bankSwitchInit:
    bankSwitched = bankSwitched or bank.int > 0

  if bankSwitched:
    raise newException(ValueError, "bankswitched NSFs not supported")


  cartridge.mapper = 0
  cartridge.mirror = 0

  cartridge.battery = false
  cartridge.chr = newSeq[uint8](0x2000)

  var prg = newSeq[uint8](0x8000)

  let prgBootstrapStart = file.readBytes(prg, header.loadAddr - 0x8000, 0x8000) + 0x8000

  # We are going to write a bootstrap program in assembly

  echo "LOAD: " & header.loadAddr.int.toHex(4)
  echo "INIT: " & header.initAddr.int.toHex(4)
  echo "PLAY: " & header.playAddr.int.toHex(4)

  # initialize writing PC
  var pc = prgBootstrapStart
  echo "the pc is " & pc.toHex(4)

  # http://www.nullsleep.com/treasure/nsf_cart_guide/

  pc.createLabel labelResetRoutine
  # CLD
  prg.writeByte(pc, 0xD8)
  # SEI
  prg.writeByte(pc, 0x78)
  # LDA #$00
  # STA $2000
  prg.writeLdaImmStaAddr(pc, 0x00, 0x2000)

  pc.createLabel labelWaitV1
  # LDA $2002
  prg.writeByte(pc, 0xAD)
  prg.writeWord(pc, 0x2002)
  # BPL WaitV1
  prg.writeRelativeBranch(pc, 0x10, labelWaitV1)

  pc.createLabel labelWaitV2
  # LDA $2002
  prg.writeByte(pc, 0xAD)
  prg.writeWord(pc, 0x2002)
  # BPL WaitV2
  prg.writeRelativeBranch(pc, 0x10, labelWaitV2)

  # Clear Sound Registers
  # LDA #$00
  prg.writeLdaImm(pc, 0x00)
  # LDX #$00
  prg.writeByte(pc, 0xA2)
  prg.writeByte(pc, 0x00)

  pc.createLabel labelClearSound
  # STA $4000,X
  prg.writeByte(pc, 0x9D)
  prg.writeWord(pc, 0x4000)
  # INX
  prg.writeByte(pc, 0xE8)
  # CPX #$0F
  prg.writeByte(pc, 0xE0)
  prg.writeByte(pc, 0x0F)
  # BNE ClearSound
  prg.writeRelativeBranch(pc, 0xD0, labelClearSound)

  # LDA #$10
  # STA $4010
  prg.writeLdaImmStaAddr(pc, 0x10, 0x4010)
  # LDA #$00
  prg.writeLdaImm(pc, 0x00)
  # STA $4011
  prg.writeStaAddr(pc, 0x4011)
  # STA $4012
  prg.writeStaAddr(pc, 0x4012)
  # STA $4013
  prg.writeStaAddr(pc, 0x4013)

  # Enable Sound Channels
  # LDA #$0F
  # STA $4015
  prg.writeLdaImmStaAddr(pc, 0x0F, 0x4015)

  # Reset Frame Counter and Clock Divider
  # LDA #$C0
  # STA $4017
  prg.writeLdaImmStaAddr(pc, 0xC0, 0x4017)

  # Set Song # & PAL/NTSC Setting
  # LDA #$00  ; song 0
  prg.writeLdaImm(pc, songNumber.uint8)
  # LDX #$00  ; NTSC
  prg.writeByte(pc, 0xA2)
  prg.writeByte(pc, 0x00)
  # JSR init
  prg.writeByte(pc, 0x20)
  prg.writeWord(pc, header.initAddr)

  # Enable VBlank NMI
  # LDA #$80
  # STA $2000
  prg.writeLdaImmStaAddr(pc, 0x80, 0x2000)

  pc.createLabel labelLoop
  # JMP Loop
  prg.writeByte(pc, 0x4C)
  prg.writeWord(pc, labelLoop)

  pc.createLabel labelNMIRoutine
  # LDA $2002
  prg.writeByte(pc, 0xAD)
  prg.writeWord(pc, 0x2002)
  # LDA #$00
  # STA $2000
  prg.writeLdaImmStaAddr(pc, 0x00, 0x2000)
  # LDA #$80
  # STA $2000
  prg.writeLdaImmStaAddr(pc, 0x80, 0x2000)
  # JSR play
  prg.writeByte(pc, 0x20)
  prg.writeWord(pc, header.playAddr)

  pc.createLabel labelIRQRoutine
  # RTI
  prg.writeByte(pc, 0x40)


  pc = 0xFFFA
  prg.writeWord(pc, labelNMIRoutine)
  prg.writeWord(pc, labelResetRoutine)
  prg.writeWord(pc, labelIRQRoutine)

  cartridge.prg = prg
