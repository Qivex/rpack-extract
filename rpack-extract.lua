local cdef = [[
int fwrite(const void *data, size_t length, size_t count, void *rpackFile);
int fread(void *data, size_t length, size_t count, void *rpackFile);
int uncompress(uint8_t *dest, unsigned long *destLen, const uint8_t *source, unsigned long sourceLen);

typedef struct {
	char signature[4];
	uint32_t version;
	uint32_t compressionMethod;
	uint32_t partAmount;
	uint32_t sectionAmount;
	uint32_t fileAmount;
	uint32_t filenameChunkLength;
	uint32_t filenameAmount;
	uint32_t blockSize;
} header;

typedef struct {
	uint8_t filetype;
	uint8_t unknown1;
	uint8_t unknown2;
	uint8_t unknown3;
	uint32_t offset;
	uint32_t unpackedSize;
	uint32_t packedSize;
	uint32_t unknown4;
} sectionInfo;

typedef struct {
	uint8_t sectionIndex;
	uint8_t unknown1;
	uint16_t fileIndex;
	uint32_t offset;
	uint32_t size;
	uint32_t unknown2;
} partInfo;

typedef struct {
	uint8_t partAmount;
	uint8_t unknown1;
	uint8_t filetype;
	uint8_t unknown2;
	uint32_t fileIndex;
	uint32_t firstPart;
} fileInfo;
]]


local RESOURCE_TYPE_LOOKUP = {
	[0x10] = "mesh",
	[0x12] = "skin",
	[0x20] = "texture",
	[0x30] = "material",
	[0x40] = "animation",
	[0x41] = "animation_id",
	[0x42] = "animation_scr",
	[0x50] = "fx",
	[0x60] = "lightmap",
	[0x61] = "flash",
	[0x65] = "sound",
	[0x66] = "sound_music",
	[0x67] = "sound_speech",
	[0x68] = "sound_stream",
	[0x69] = "sound_local",
	[0x70] = "density_map",
	[0x80] = "height_map",
	[0x90] = "mimic",
	[0xA0] = "pathmap",
	[0xB0] = "phonemes",
	[0xC0] = "static_geometry",
	[0xD0] = "text",
	[0xE0] = "binary",
	[0xF8] = "tiny_objects",
	[0xFF] = "resource_list"
}


function inflate(compressedData, uncompressedLength)
	local resultBuffer = ffi.new("uint8_t[?]", uncompressedLength)
	local resultLength = ffi.new("unsigned long[1]", uncompressedLength)
	local code = zlib.uncompress(resultBuffer, resultLength, compressedData, #compressedData)
	return ffi.string(resultBuffer, resultLength[0])
end


function extract(path)
	local rpackFile = io.open(path, "rb")
	local header = ffi.new("header")
	ffi.C.fread(header, ffi.sizeof("header"), 1, rpackFile)

	local offsetMultiplier = 1
	if header.version == 4 then
		offsetMultiplier = 16
	end
	
	local sectionInfos = ffi.new("sectionInfo[?]", header.sectionAmount)
	ffi.C.fread(sectionInfos, ffi.sizeof("sectionInfo"), header.sectionAmount, rpackFile)
	
	local partInfos = ffi.new("partInfo[?]", header.partAmount)
	ffi.C.fread(partInfos, ffi.sizeof("partInfo"), header.partAmount, rpackFile)

	local fileInfos = ffi.new("fileInfo[?]", header.fileAmount)
	ffi.C.fread(fileInfos, ffi.sizeof("fileInfo"), header.fileAmount, rpackFile)
	
	local filenameOffsets = ffi.new("uint32_t[?]", header.fileAmount)
	ffi.C.fread(filenameOffsets, ffi.sizeof("uint32_t"), header.fileAmount, rpackFile)
	
	local filenameChunk = ffi.new("char[?]", header.filenameChunkLength)
	ffi.C.fread(filenameChunk, ffi.sizeof("char"), header.filenameChunkLength, rpackFile)
	local filenameChunkLuaString = ffi.string(filenameChunk, header.filenameChunkLength)
	
	local sectionHandles = {}
	local extractFolder = path:gsub("%.rpack", "")
	os.execute(string.format('mkdir "%s" 2> nul', extractFolder))
	for i=0, header.sectionAmount-1 do
		local packedSize = sectionInfos[i].packedSize
		if packedSize > 0 then
			local unpackedSize = sectionInfos[i].unpackedSize
			local compressedBuffer = ffi.new("uint8_t[?]", packedSize)
			rpackFile:seek("set", sectionInfos[i].offset * offsetMultiplier)
			ffi.C.fread(compressedBuffer, ffi.sizeof("uint8_t"), packedSize, rpackFile)
			local uncompressedBuffer = inflate(ffi.string(compressedBuffer, packedSize), unpackedSize)
			local sectionFile = io.open(string.format("%s\\%u.section", extractFolder, i), "wb+")
			ffi.C.fwrite(uncompressedBuffer, ffi.sizeof("uint8_t"), unpackedSize, sectionFile)
			sectionHandles[i] = sectionFile
		end
	end
	
	for i=0, header.fileAmount-1 do
		local resourceType = RESOURCE_TYPE_LOOKUP[fileInfos[i].filetype] or "unknown"
		local filename = string.match(filenameChunkLuaString, "(.-)%z", filenameOffsets[i] + 1)
		local targetPath = string.format("%s\\%s\\%s", extractFolder, resourceType, filename)
		local targetFile = io.open(targetPath, "wb")
		if not targetFile then
			os.execute(string.format('mkdir "%s\\%s" 2> nul', extractFolder, resourceType))
			targetFile = io.open(targetPath, "wb")
		end
		local currentPart = fileInfos[i].firstPart
		for p=0, fileInfos[i].partAmount-1 do
			local currentSection = partInfos[currentPart].sectionIndex
			local dataLength = partInfos[currentPart].size
			local dataBuffer = ffi.new("char[?]", dataLength)
			local sourceFile, offset
			if sectionHandles[currentSection] then
				sourceFile = sectionHandles[currentSection]
				offset = partInfos[currentPart].offset
			else
				sourceFile = rpackFile
				offset = sectionInfos[currentSection].offset + partInfos[currentPart].offset
			end
			sourceFile:seek("set", offset * offsetMultiplier)
			ffi.C.fread(dataBuffer, ffi.sizeof("char"), dataLength, sourceFile)
			ffi.C.fwrite(dataBuffer, ffi.sizeof("char"), dataLength, targetFile)
			currentPart = currentPart + 1
		end
		targetFile:close()
	end
	
	rpackFile:close()
	for i, handle in pairs(sectionHandles) do
		handle:close()
		os.remove(string.format("%s\\%u.section", extractFolder, i))
	end
end


function main()
	local packs = {}
	local dir = io.popen("dir *.rpack /b")
	for rpack in dir:lines() do
		table.insert(packs, rpack)
	end
	dir:close()
	for _, rpack in pairs(packs) do
		io.write(string.format('Extracting "%s" ', rpack))
		local success = pcall(extract, rpack)
		print(success and "done!" or "failed! (use debug script to learn why)")
	end
end


if jit and jit.os == "Windows" then
	ffi = require("ffi")
	zlib = ffi.load("zlib1")
	ffi.cdef(cdef)
	main()
else
	print("Requires LuaJIT (for FFI)!")
end
