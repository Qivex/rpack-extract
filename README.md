# RPack Unpacker
This script can be used to extract all files bundled inside [Chrome Engine](https://en.wikipedia.org/wiki/Chrome_Engine) & [C-Engine](https://en.wikipedia.org/wiki/Dying_Light_2) Resource Packs (`.rpack` extension).
Please consider the license(s) of the product containing the rpack files before extracting!


## Requirements
To execute this script you will need:
- [LuaJIT](https://luajit.org/download.html)
- [zlib](https://www.zlib.net/)
- Windows [^1]

[^1]: If this upsets you, turn off your Linux machine and go back to the system where you legally obtained your rpack files anyway...


## Usage
Place the `zlib1.dll` in the directory of the **LuaJIT executable**.
Execute the script in the directory of the **rpack files** to unpack all of them into respective folders of the same name.
```
luajit rpack-extract.lua
```

Use the debug version of the script only if the extraction fails.
While offering the same behavior, it is designed to be as verbose as possible.
Therefore redirecting its output to a log-file is **highly** recommended.
```
luajit rpack-extract-debug.lua > extract.log
```

In the debug script you can also disable certain capabilities by changing the following config values at the top:
| Config value | Description |
| --- | --- |
| `enableBenchmarking` | Set to false if your system does not support `GetTickCount()` |
| `onlyDecodeHeader` | Set to true if you only want to log header content without extracting any file |
| `noZlib` | Set to true if you know (or failed to compile zlib and hope) the rpack is not compressed |
| `decompressIntoMemory` | Not yet implemented (currently all compressed sections are written into output folder once decompressed) |


## File extensions
While some rpacks include file extensions - most of them don't.
Even if a file has an extension **do not assume** that it adheres to the corresponding filetype specifications (like DDS or PNG).
Most games apply custom logic to the files depending on the resource type, both before packing and after extraction.
This usually includes removing file extensions and replacing headers with custom ones (but can also include adding flags, compression or encryption).

Because these additional transformations are not part of the rpack-format itself, they are not applied in this script.
The files are extracted exactly the way they are packed.
However, to ease postprocessing of the extracted files, they are grouped by resource type - represented as subfolders in the output folder.
If you want to recover the original files, you will have to recreate the custom logic yourself.

For example, Dying Light uses the following mapping:
| Resource type | Extension |
| --- | --- |
| mesh | .msh |
| texture | .dds |
| material | .mat |
| fx | .fx |
| text | .txt |
| binary | .bin |
(as found in `\Engine\Data\ResourcePackCfg.scr` of the [Dying Light Developer Tools](https://store.steampowered.com/app/239140/))


## Similar tools
- Unpacker for [RP5L](https://github.com/hhrhhr/rp5l) and [RP6L](https://gist.github.com/hhrhhr/c270fa8dd41abcc08f0cab652164130b) rpacks by [Dmitry Zaitsev](https://github.com/hhrhhr)
- Plugin for 010 Editor on [NexusMods](https://www.nexusmods.com/dyinglight2/mods/583)