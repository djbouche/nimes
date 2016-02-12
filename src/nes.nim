import nes.types, nes.cpu, nes.apu, nes.ppu, nes.cartridge, nes.controller,
  nes.mapper, nes.mem

export types.NES, types.FileType, types.NESObj, types.Buttons, setButtons, resolution

proc newNES*(path: string, fileType: FileType = ftINES, songNumber: int = 0): NES =
  new result
  try:
    result.cartridge = newCartridge(path, fileType, songNumber)
  except ValueError:
    raise newException(ValueError,
      "failed to open " & path & ": " & getCurrentExceptionMsg())
  result.mapper = newMapper(result)
  result.cpu = initCPU(result)
  result.apu = initAPU(result)
  result.ppu = initPPU(result)

proc reset*(nes: NES) =
  nes.cpu.reset()
  nes.ppu.reset()

proc step*(nes: NES): int =
  result = nes.cpu.step()

  for i in 1 .. result*3:
    nes.ppu.step()
    nes.mapper.step()

  when not defined(emscripten):
    for i in 1 .. result:
      nes.apu.step()

proc run*(nes: NES, seconds: float) =
  var cycles = int(cpu.frequency * seconds)
  while cycles > 0:
    cycles -= nes.step()

proc buffer*(nes: NES): var Picture =
  nes.ppu.front
