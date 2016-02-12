import "../types"

const iNESMagic = 0x1A53454E

type iNESHeader = object {.packed.}
  magic: uint32
  numPRG, numCHR, control1, control2, numRAM: uint8
  padding: array[7, uint8]

proc readINESFile*(cartridge: Cartridge, file: File) =
  var header: iNESHeader
  # Read directly into the header object
  if file.readBuffer(addr header, sizeof header) != sizeof header:
    raise newException(ValueError, "header can't be read")

  if header.magic != iNESMagic:
    raise newException(ValueError, "header not conforming to iNES format")

  let
    mapper1 = header.control1 shr 4
    mapper2 = header.control2 shr 4
  cartridge.mapper = mapper1 or (mapper2 shl 4)

  let
    mirror1 = header.control1 and 1
    mirror2 = (header.control1 shr 3) and 1
  cartridge.mirror = mirror1 or (mirror2 shl 1'u8)

  cartridge.battery = ((header.control1 shr 1) and 1) != 0

  cartridge.prg = newSeq[uint8](header.numPRG.int * 16384)
  cartridge.chr = newSeq[uint8](header.numCHR.int * 8192)

  if (header.control1 and 4) == 4:
    var trainer: array[512, uint8]
    if file.readBytes(trainer, 0, trainer.len) != trainer.len:
      raise newException(ValueError, "Trainer can't be read")

  if file.readBytes(cartridge.prg, 0, cartridge.prg.len) != cartridge.prg.len:
    raise newException(ValueError, "PRG ROM can't be read")

  if header.numCHR == 0:
    cartridge.chr.setLen(8192)
  elif file.readBytes(cartridge.chr, 0, cartridge.chr.len) != cartridge.chr.len:
    raise newException(ValueError, "CHR ROM can't be read")
