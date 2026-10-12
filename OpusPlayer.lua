local ffi = require("ffi")

local OpusPlayer = {}
OpusPlayer.__index = OpusPlayer

local opus = ffi.load("opus")
local ogg = ffi.load("ogg")

local BLOCK_SIZE = 4096
local OPUS_BLOCK_SIZE = 5760

ffi.cdef[[
    // Opus decoder
    typedef struct OpusDecoder OpusDecoder;
    OpusDecoder* opus_decoder_create(int Fs, int channels, int *error);
    void opus_decoder_destroy(OpusDecoder *st);
    int opus_decode(OpusDecoder *st, const unsigned char *data, int len, short *pcm, int frame_size, int decode_fec);

    // Ogg structures
    typedef struct {
        unsigned char *data;
        long storage;
        long fill;
        long returned;
        int unsynced;
        int headerbytes;
        int bodybytes;
    } ogg_sync_state;

    typedef struct {
        unsigned char *header;
        long header_len;
        unsigned char *body;
        long body_len;
    } ogg_page;

    typedef struct {
        unsigned char *packet;
        long bytes;
        long b_o_s;
        long e_o_s;
        int64_t granulepos;
        int64_t packetno;
    } ogg_packet;

    typedef struct {
        unsigned char *body_data;
        long body_storage;
        long body_fill;
        long body_returned;
        int *lacing_vals;
        int64_t *granule_vals;
        long lacing_storage;
        long lacing_fill;
        long lacing_packet;
        long lacing_returned;
        unsigned char header[282];
        int header_fill;
        int e_o_s;
        int b_o_s;
        long serialno;
        long pageno;
        int64_t packetno;
        int64_t granulepos;
    } ogg_stream_state;

    // Ogg functions
    int ogg_sync_init(ogg_sync_state *oy);
    int ogg_sync_clear(ogg_sync_state *oy);
    char *ogg_sync_buffer(ogg_sync_state *oy, long size);
    int ogg_sync_wrote(ogg_sync_state *oy, long bytes);
    int ogg_sync_pageout(ogg_sync_state *oy, ogg_page *og);

    int ogg_stream_init(ogg_stream_state *os, int serialno);
    int ogg_stream_clear(ogg_stream_state *os);
    int ogg_stream_pagein(ogg_stream_state *os, ogg_page *og);
    int ogg_stream_packetout(ogg_stream_state *os, ogg_packet *op);

    int ogg_page_serialno(ogg_page *og);
    int ogg_page_bos(ogg_page *og);
    int ogg_page_eos(ogg_page *og);
]]

-- dont touch or crash
local function file_read(self, bytes)
    if self.source_type == "stream" then
        if not self.file then return nil end
        local chunk = self.file:read(bytes)

        if not chunk or #chunk == 0 then return false end  -- EOF
        return chunk
    else
        if self.filepos >= #self.filedata then return false end
        local end_pos = math.min(self.filepos + bytes, #self.filedata)
        local chunk = self.filedata:sub(self.filepos + 1, end_pos)
        self.filepos = end_pos
        return chunk
    end
end

local function get_page(self)
    local page = ffi.new("ogg_page")
    local result

    repeat
        result = ogg.ogg_sync_pageout(self.sync, page)

        if result == 0 then
            local chunk = file_read(self, BLOCK_SIZE)
            if chunk == false then return nil end  -- EOF reached
            local buffer = ogg.ogg_sync_buffer(self.sync, #chunk)
            ffi.copy(buffer, chunk, #chunk)
            ogg.ogg_sync_wrote(self.sync, #chunk)
        elseif result == -1 then
            -- Not synced yet
        end
    until result == 1

    return page
end

local function get_packet(self)
    local packet = ffi.new("ogg_packet")
    local result

    if not self.stream_initialized then
        local page = get_page(self)
        if not page then return nil end
        local serialno = ogg.ogg_page_serialno(page)
        ogg.ogg_stream_init(self.stream, serialno)
        self.stream_initialized = true
        ogg.ogg_stream_pagein(self.stream, page)
    end

    repeat
        result = ogg.ogg_stream_packetout(self.stream, packet)
        if result == 0 then
            local page = get_page(self)
            if not page then return nil end
            ogg.ogg_stream_pagein(self.stream, page)
        elseif result == -1 then
            -- keep trying
        end
    until result == 1

    return packet
end

-- Scans the whole stream once to find the last granule position (= duration).
-- Works for both source types now:
--   static sources scan the in-memory filedata, as before.
--   stream  sources scan through the real file handle. Since that handle
local function compute_duration(self)
    local temp, savedPos

    if self.source_type == "static" then
        temp = {filedata = self.filedata, filepos = 0, source_type = "static"}
    else
        if not self.file then
            self.duration_samples = 0
            return
        end
        savedPos = self.file:tell()
        self.file:seek(0)
        temp = {file = self.file, source_type = "stream"}
    end

    local last_granule = 0
    local sync = ffi.new("ogg_sync_state")
    local stream = ffi.new("ogg_stream_state")
    local stream_initialized = false

    ogg.ogg_sync_init(sync)

    while true do
        local chunk = file_read(temp, 4096)
        if chunk == false then break end

        local buffer = ogg.ogg_sync_buffer(sync, #chunk)
        ffi.copy(buffer, chunk, #chunk)
        ogg.ogg_sync_wrote(sync, #chunk)

        local page = ffi.new("ogg_page")
        while ogg.ogg_sync_pageout(sync, page) == 1 do
            if not stream_initialized then
                local serialno = ogg.ogg_page_serialno(page)
                ogg.ogg_stream_init(stream, serialno)
                stream_initialized = true
            end

            ogg.ogg_stream_pagein(stream, page)

            local packet = ffi.new("ogg_packet")
            while ogg.ogg_stream_packetout(stream, packet) == 1 do
                if tonumber(packet.granulepos) > 0 then
                    last_granule = tonumber(packet.granulepos)
                end
            end
        end
    end

    -- Clean up
    if stream_initialized then
        ogg.ogg_stream_clear(stream)
    end
    ogg.ogg_sync_clear(sync)

    self.duration_samples = math.max(0, last_granule - (self.pre_skip or 0))

    if self.source_type == "stream" and savedPos then
        self.file:seek(savedPos)
    end
end

function OpusPlayer.newSource(filename, source_type)
    source_type = source_type or "stream"

    if source_type ~= "stream" and source_type ~= "static" then
        error("source_type must be 'stream' or 'static'")
    end

    local self = setmetatable({}, OpusPlayer)
    self.source_type = source_type

    local info = love.filesystem.getInfo(filename)
    if not info then
        error("File not found: " .. filename)
    end

    if source_type == "stream" then
        -- Open file handle for streaming
        self.file = love.filesystem.openFile(filename, "r")
        if not self.file then
            error("Failed to open file: " .. filename)
        end

        -- Verify Ogg container
        local magic = self.file:read(4)
        if magic ~= "OggS" then
            error("Not a valid Ogg file")
        end
        self.file:seek(0)
    else
        -- Load entire file into memory for static
        self.filedata = love.filesystem.read(filename)
        self.filepos = 0

        if not self.filedata then
            error("Failed to read file: " .. filename)
        end

        -- Verify Ogg container
        if self.filedata:sub(1, 4) ~= "OggS" then
            error("Not a valid Ogg file")
        end
    end

    -- Initialize Ogg sync/stream
    self.sync = ffi.new("ogg_sync_state")
    self.stream = ffi.new("ogg_stream_state")
    self.stream_initialized = false
    ogg.ogg_sync_init(self.sync)

    -- Skip headers
    for i = 1, 2 do
        local packet = get_packet(self)
        if not packet then
            error("Failed to read header packet " .. i)
        end

        -- Verify first packet is OpusHead
        if i == 1 then
            local bytes = tonumber(packet.bytes)
            local header = ffi.string(packet.packet, math.min(8, bytes))
            if not header:match("OpusHead") then
                error("Not a valid Opus file")
            end

            self.pre_skip = (bytes >= 12) and (packet.packet[10] + packet.packet[11] * 256) or 0
        end
    end

    -- Default to 48kHz stereo
    local samplerate = 48000
    local channels = 2

    -- Create Opus decoder
    local err = ffi.new("int[1]")
    self.decoder = opus.opus_decoder_create(samplerate, channels, err)
    if err[0] ~= 0 then
        error("Failed to create Opus decoder: " .. err[0])
    end

    -- Create audio source
    self.source = love.audio.newQueueableSource(samplerate, 16, channels)
    self.samplerate = samplerate
    self.channels = channels

    self.decoded_samples = 0
    self.played_samples = 0

    self.queued_samples = 0
    self.buffer_samples = {}
    self.user_paused = false
    self.duration_samples = nil

    self.packets_decoded = 0
    self.finished = false

    -- Reused across every decoded packet instead of allocating a fresh
    -- ffi.new("short[?]", ...) each time update() queues one (see update()
    -- below) — with several of these running at once (a multi-stem chart's
    -- StemPlayer drives one OpusPlayer per stem, every frame), that was a
    -- lot of avoidable allocation/GC churn on top of the much bigger cost
    -- fixed there.
    self.pcmBuffer = ffi.new("short[?]", OPUS_BLOCK_SIZE * 2)

    return self
end

function OpusPlayer:getType()
    return self.source_type
end

function OpusPlayer:play()
    if self.source and not self.user_paused then return end
    self.user_paused = false
    self.source:play()
end

function OpusPlayer:pause()
    if not self.source or self.user_paused then return end
    print("pause press")
    self.user_paused = true
    self.source:pause()
end

function OpusPlayer:stop()
    if not self.source then return end

    self.source:stop()
    self.stopped = true

    -- Reset playback
    self.decoded_samples = 0
    self.played_samples = 0
    self.queued_samples = 0
    self.buffer_samples = {}
    self.packets_decoded = 0
    self.finished = false
    self.last_free_buffers = nil

    if self.source_type == "static" then
        self.filepos = 0
    else
        if self.file then
            self.file:seek(0)
        end
    end

    -- Reinitialize Ogg stream state
    if self.stream_initialized then
        ogg.ogg_stream_clear(self.stream)
        self.stream_initialized = false
    end
    if self.sync then
        ogg.ogg_sync_clear(self.sync)
        ogg.ogg_sync_init(self.sync)
    end

    -- Skip again
    for i = 1, 2 do
        local packet = get_packet(self)
        if not packet then
            error("Failed to read header packet " .. i .. " after stop")
        end
    end
end

function OpusPlayer:setVolume(volume)
    if self.source then
        self.source:setVolume(volume)
    end
end

function OpusPlayer:getVolume()
    return self.source and self.source:getVolume() or 1
end

function OpusPlayer:isPlaying()
    return self.source and self.source:isPlaying()
end

function OpusPlayer:getDuration(unit)
    if not self.duration_samples then
        compute_duration(self)
    end

    unit = unit or "seconds"

    if unit == "seconds" then
        return self.duration_samples / self.samplerate
    elseif unit == "samples" then
        return self.duration_samples
    else
        error("Invalid unit for getDuration(): must be 'seconds' or 'samples'")
    end
end

function OpusPlayer:tell(unit)
    if not self.source then return 0 end

    unit = unit or "seconds"

    local current_samples = self.decoded_samples - self.queued_samples

    if unit == "seconds" then
        return current_samples / self.samplerate
    elseif unit == "samples" then
        return current_samples
    else
        error("Invalid unit for tell(): must be 'seconds' or 'samples'")
    end
end

function OpusPlayer:update(packets_per_frame)
    packets_per_frame = packets_per_frame or 8

    if not self.source or self.finished then return end

    local free = self.source:getFreeBufferCount()

    -- Calculate how many buffers were consumed since last update
    if self.last_free_buffers then
        local buffers_consumed = free - self.last_free_buffers

        -- Remove consumed buffers from tracking
        for i = 1, buffers_consumed do
            local samples = table.remove(self.buffer_samples, 1)
            if samples then
                self.played_samples = self.played_samples + samples
            end
        end
    end

    -- Store current free count BEFORE queuing new buffers
    local free_before_queue = free

    -- Queue new buffers
    if free > 0 then
        for _ = 1, math.min(free, packets_per_frame) do
            local packet = get_packet(self)
            if not packet then
                self.finished = true
                break
            end

            local bytes = tonumber(packet.bytes)

            if bytes == 0 then
                self.finished = true
                break
            end

            local pcm = self.pcmBuffer
            local samples = opus.opus_decode(self.decoder, packet.packet, tonumber(packet.bytes), pcm, OPUS_BLOCK_SIZE, 0)

            if samples > 0 then
                local sd = love.sound.newSoundData(samples, self.samplerate, 16, self.channels)
                ffi.copy(sd:getPointer(), pcm, samples * self.channels * 2)

                self.source:queue(sd)
                table.insert(self.buffer_samples, samples)

                self.decoded_samples = self.decoded_samples + samples
                self.packets_decoded = self.packets_decoded + 1

            elseif samples == 0 then
                self.finished = true
                break
            else
                error("Opus decode error: " .. samples)
            end
        end

        if not self.source:isPlaying() and self.packets_decoded > 0 and not self.finished and not self.user_paused then
            self.source:play()
        end
    end

    -- Recalculate queued_samples from buffer_samples array
    self.queued_samples = 0
    for _, samples in ipairs(self.buffer_samples) do
        self.queued_samples = self.queued_samples + samples
    end

    -- Store free count AFTER queuing for next frame
    self.last_free_buffers = self.source:getFreeBufferCount()
end

function OpusPlayer:getStats()
    return {
        packets_decoded = self.packets_decoded,
        free_buffers = self.source and self.source:getFreeBufferCount() or 0,
        is_playing = self:isPlaying(),
        finished = self.finished,
        source_type = self.source_type
    }
end

function OpusPlayer:destroy()
    if self.decoder then
        opus.opus_decoder_destroy(self.decoder)
        self.decoder = nil
    end
    if self.stream and self.stream_initialized then
        ogg.ogg_stream_clear(self.stream)
        self.stream = nil
    end
    if self.sync then
        ogg.ogg_sync_clear(self.sync)
        self.sync = nil
    end
    if self.source then
        self.source:stop()
        self.source = nil
    end
    if self.file then
        self.file:close()
        self.file = nil
    end

    self.filedata = nil
end

return OpusPlayer
