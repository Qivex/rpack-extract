local args = {...}
----------------------
-- ADVANCED OPTIONS --
----------------------

-- Show timing info in output
local enableBenchmarking = true

-- Skip extracting and only log header-content
local onlyDecodeHeader = false

-- Skip loading zlib library (only works when rpack is uncompressed)
local disableZlib = false

-- NYI: Extract compressed sections into memory instead of output-folder
local decompressIntoMemory = false



--------------------
-- C DECLARATIONS --
--------------------

local stdio_cdef = [[
int fwrite(const void *data, size_t length, size_t count, void *file);
int fread(void *data, size_t length, size_t count, void *file);
]]


local rpack_cdef = [[
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

local zlib_cdef = [[
int uncompress(uint8_t *dest, unsigned long *destLen, const uint8_t *source, unsigned long sourceLen);
]]



---------------
-- CONSTANTS --
---------------

-- From Dying Light Developer Tools (ResourcePackCfg.scr)
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



-------------
-- METHODS --
-------------

function printf(...)
	print(string.format(...))
end


function benchmark(func)
	ffi.cdef("uint32_t GetTickCount();")
	return function(...)
		local startTick = ffi.C.GetTickCount()
		func(...)
		printf("Finished in %u ms", ffi.C.GetTickCount() - startTick)
	end
end


function inflate(compressedData, uncompressedLength)
	local resultBuffer = ffi.new("uint8_t[?]", uncompressedLength)
	local resultLength = ffi.new("unsigned long[1]", uncompressedLength)
	local code = zlib.uncompress(resultBuffer, resultLength, compressedData, #compressedData)
	assert(code == 0, "From zlib: Inflate was not successful!")
	return ffi.string(resultBuffer, resultLength[0])
end


function extract(path)
	print("Extracting " .. path .. "\n")
	
	-- Open file
	local rpackFile = io.open(path, "rb")
	
	-- Load header
	local header = ffi.new("header")
	assert(
		ffi.C.fread(header, ffi.sizeof("header"), 1, rpackFile) == 1,
		"Invalid header!"
	)
	local signature = ffi.string(header.signature, 4)
	assert(
		signature == "RP6L",
		string.format("Unsupported signature: %s (expected RP6L)", signature)
	)
	assert(
		header.version == 1 or header.version == 4,
		string.format("Unsupported version: %u (expected 1 or 4)", header.version)
	)
	assert(
		header.compressionMethod == 0 or header.compressionMethod == 1,
		string.format("Unknown compression method: %u (expected 0 = no compression or 1 = zlib)", header.compressionMethod)
	)
	printf(
		"File:\n%s version %u with %s compression\nContains %u files (spread into %u sections with %u total parts)",
		signature,
		header.version,
		header.compressionMethod == 1 and "zlib" or "no",
		header.fileAmount,
		header.sectionAmount,
		header.partAmount
	)
	local offsetMultiplier = 1
	if header.version == 4 then
		offsetMultiplier = 16
	end
	
	-- Load sectionInfos
	local sectionInfos = ffi.new("sectionInfo[?]", header.sectionAmount)
	local actualSectionCount = ffi.C.fread(sectionInfos, ffi.sizeof("sectionInfo"), header.sectionAmount, rpackFile)
	assert(
		actualSectionCount == header.sectionAmount,
		string.format("Section info incomplete: %u instead of %u entries!", actualSectionCount, header.sectionAmount)
	)
	print("\nSections:")
	for i=0, header.sectionAmount-1 do
		printf(
			"type=%u, offset=%u, unpacked=%u, packed=%u",
			sectionInfos[i].filetype,
			sectionInfos[i].offset * offsetMultiplier,
			sectionInfos[i].unpackedSize,
			sectionInfos[i].packedSize
		)
	end
	
	-- Load partInfos
	local partInfos = ffi.new("partInfo[?]", header.partAmount)
	local actualPartCount = ffi.C.fread(partInfos, ffi.sizeof("partInfo"), header.partAmount, rpackFile)
	assert(
		actualPartCount == header.partAmount,
		string.format("Part info incomplete: %u instead of %u entries!", actualPartCount, header.partAmount)
	)
	print("\nParts:")
	for i=0, header.partAmount-1 do
		printf(
			"section=%u, file=%u, offset=%u, size=%u",
			partInfos[i].sectionIndex,
			partInfos[i].fileIndex,
			partInfos[i].offset * offsetMultiplier,
			partInfos[i].size
		)
	end
	
	-- Load fileInfos
	local fileInfos = ffi.new("fileInfo[?]", header.fileAmount)
	local actualFileCount = ffi.C.fread(fileInfos, ffi.sizeof("fileInfo"), header.fileAmount, rpackFile)
	assert(
		actualFileCount == header.fileAmount,
		string.format("File info incomplete: %u instead of %u entries!", actualFileCount, header.fileAmount)
	)
	print("\nFiles:")
	for i=0, header.fileAmount-1 do
		printf(
			"parts=%u, type=%u, index=%u, firstpart=%u",
			fileInfos[i].partAmount,
			fileInfos[i].filetype,
			fileInfos[i].fileIndex,
			fileInfos[i].firstPart
		)
	end
	
	-- Load filenameOffsets
	local filenameOffsets = ffi.new("uint32_t[?]", header.fileAmount)
	local actualOffsetCount = ffi.C.fread(filenameOffsets, ffi.sizeof("uint32_t"), header.fileAmount, rpackFile)
	assert(
		actualOffsetCount == header.fileAmount,
		string.format("Filename info incomplete: %u instead of %u entries!", actualOffsetCount, header.fileAmount)
	)
	print("\nFilename Offsets:")
	for i=0, header.fileAmount-1 do
		print(i, filenameOffsets[i])
	end
	
	-- Load filenames (as single chunk)
	local filenameChunk = ffi.new("char[?]", header.filenameChunkLength)
	local actualFilenameChunkLength = ffi.C.fread(filenameChunk, ffi.sizeof("char"), header.filenameChunkLength, rpackFile)
	assert(
		actualFilenameChunkLength == header.filenameChunkLength,
		string.format("Filename chunk too short: %u instead of %u chars!", actualPartCount, header.partAmount)
	)
	local filenameChunkLuaString = ffi.string(filenameChunk, header.filenameChunkLength)
	print("\nFilename Chunk:")
	print(filenameChunkLuaString)
	
	-- Finish header parsing
	print("\nParsed header successfully!\n")
	if onlyDecodeHeader == true then
		return
	end
	
	-- Inflate compressed sections
	local sectionHandles = {}
	local extractFolder = path:gsub("%.rpack", "")
	os.execute(string.format('mkdir "%s" 2> nul', extractFolder))
	for i=0, header.sectionAmount-1 do
		local packedSize = sectionInfos[i].packedSize
		if packedSize > 0 then
			print("Inflating compressed section " .. i)
			assert(zlib, "Compressed rpack requires zlib!")
			local unpackedSize = sectionInfos[i].unpackedSize
			-- Read compressed section
			local compressedBuffer = ffi.new("uint8_t[?]", packedSize)
			rpackFile:seek("set", sectionInfos[i].offset * offsetMultiplier)
			ffi.C.fread(compressedBuffer, ffi.sizeof("uint8_t"), packedSize, rpackFile)
			-- Inflate section
			local uncompressedBuffer = inflate(ffi.string(compressedBuffer, packedSize), unpackedSize)
			-- Write to folder
			local sectionFile = io.open(string.format("%s\\%u.section", extractFolder, i), "wb+")
			ffi.C.fwrite(uncompressedBuffer, ffi.sizeof("uint8_t"), unpackedSize, sectionFile)
			-- Keep handle open for reading
			sectionHandles[i] = sectionFile
		end
	end
	print()
	
	-- Extract all files
	for i=0, header.fileAmount-1 do
		-- Determine path
		local resourceType = RESOURCE_TYPE_LOOKUP[fileInfos[i].filetype] or "unknown"
		local filename = string.match(filenameChunkLuaString, "(.-)%z", filenameOffsets[i] + 1)
		local targetPath = string.format("%s\\%s\\%s", extractFolder, resourceType, filename)
		print("Extracting " .. targetPath)
		-- Open handle
		local targetFile = io.open(targetPath, "wb")
		if not targetFile then
			os.execute(string.format('mkdir "%s\\%s" 2> nul', extractFolder, resourceType))
			targetFile = io.open(targetPath, "wb")
		end
		-- Append parts
		local currentPart = fileInfos[i].firstPart
		for p=0, fileInfos[i].partAmount-1 do
			local currentSection = partInfos[currentPart].sectionIndex
			local dataLength = partInfos[currentPart].size
			local dataBuffer = ffi.new("char[?]", dataLength)
			-- Difference between compressed and uncompressed sections!
			local sourceFile, offset
			if sectionHandles[currentSection] then
				sourceFile = sectionHandles[currentSection]
				offset = partInfos[currentPart].offset
			else
				sourceFile = rpackFile
				offset = sectionInfos[currentSection].offset + partInfos[currentPart].offset
			end
			-- Copy from source to target
			sourceFile:seek("set", offset * offsetMultiplier)
			ffi.C.fread(dataBuffer, ffi.sizeof("char"), dataLength, sourceFile)
			ffi.C.fwrite(dataBuffer, ffi.sizeof("char"), dataLength, targetFile)
			currentPart = currentPart + 1
		end
		targetFile:close()
	end
	
	-- Remove temporary uncompressed sections
	for i, handle in pairs(sectionHandles) do
		handle:close()
		local success, message = os.remove(string.format("%s\\%u.section", extractFolder, i))
		assert(success, "Could not delete temporary section: " .. message)
	end
	
	-- Close source file
	rpackFile:close()
end


function main()
	-- Help if any arg
	if #args > 0 then
		printHelp()
		return
	end
	-- Find all rpack-files
	local packs = {}
	local dir = io.popen("dir *.rpack /b")
	for rpack in dir:lines() do
		table.insert(packs, rpack)
	end
	dir:close()
	-- Help if no rpack was found
	if #packs <= 0 then
		printHelp()
		return
	end
	-- Benchmark
	if enableBenchmarking then
		extract = benchmark(extract)
	end
	-- Extract them one by one
	for _, rpack in pairs(packs) do
		local success, errorMessage = pcall(extract, rpack)	-- Continue with next file on error
		if not success then
			print(errorMessage)
		end
	end
end


function printHelp()
	print("This script extracts all rpack-files found in the current directory into seperate folders.\nTips:\n- For large rpack files a SSD is highly recommended\n\nOptions:\n")
end


if jit and jit.os == "Windows" then
	ffi = require("ffi")
	ffi.cdef(rpack_cdef)
	ffi.cdef(stdio_cdef)
	if not disableZlib then
		ffi.cdef(zlib_cdef)
		zlib = ffi.load("zlib1")
	end
	main()
else
	print("Requires LuaJIT (for FFI)!")
end
