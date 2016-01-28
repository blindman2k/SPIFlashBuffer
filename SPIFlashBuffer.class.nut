// Copyright (c) 2016 Electric Imp
// This file is licensed under the MIT License
// http://opensource.org/licenses/MIT
 
const SPIFLASHBUFFER_SECTOR_SIZE = 4096;
const SPIFLASHBUFFER_META_MAGIC = "SFBUF";
const SPIFLASHBUFFER_META_SIZE = 7;
const SPIFLASHBUFFER_META_PARTIAL = 0x7FFFFFFF;
const SPIFLASHBUFFER_META_FREE = 0xFFFFFFFF;


class SPIFlashBuffer {
    
    _flash = null;
    _size = null;
    _free = null;
    _sectors = null;
    _enables = 0;
    _erasing = false;
    _began = false;
    
    // These are relative to the start of the SPI flash
    _start = null;
    _end = null;
    _meta_start = null;
    _data_start = null;
    
    // These are relative to the start of the meta data
    _meta_len_pos = 0;
    
    // These are relative to the end of the meta data
    _write_pos = 0;
    _read_pos = 0;
    
    static version = [1, 0, 0];
    static className = "SPIFlashBuffer"

    static ERR_BEGIN = "You must call begin() before writing to the buffer"
    static ERR_INVALID_START = "Invalid start value"
    static ERR_INVALID_END = "Invalid end value"
    static ERR_INVALID_BOUNDARY = "The buffer must start and end at a sector boundary"
    static ERR_BUFFER_TOO_SMALL = "Buffer must be at least two sectors long"
    static ERR_META_IS_INVALID = "Meta header is invalid. Create new meta data."
    static ERR_TRANSACTION_ABORTED = "The last transaction did not complete. Create new meta data."
    static ERR_INVALID_OFFSET = "Invalid offset basis"


    //--------------------------------------------------------------------------
    // Notes: start and end must be aligned with sector boundaries.
    constructor(start = null, end = null, flash = null) {

        _flash = flash ? flash : hardware.spiflash;

        _enable();
        local flash_size = _flash.size();
        _disable();
        
        if (start == null) _start = 0;
        else if (start < flash_size) _start = start;
        else throw ERR_INVALID_START;
        if (_start % SPIFLASHBUFFER_SECTOR_SIZE != 0) throw ERR_INVALID_BOUNDARY;
        
        if (end == null) _end = flash_size;
        else if (end > _start) _end = end;
        else throw ERR_INVALID_END;
        if (_end % SPIFLASHBUFFER_SECTOR_SIZE != 0) throw ERR_INVALID_BOUNDARY;

        // NOTE: Initially we assume the meta data will be stored at _start
        _meta_start = _start;
        _meta_len_pos = SPIFLASHBUFFER_META_SIZE;
        _data_start = _meta_start + SPIFLASHBUFFER_SECTOR_SIZE;
        _free = _end - _data_start;
        _size = _end - _start;
        _sectors = _size / SPIFLASHBUFFER_SECTOR_SIZE;

        if (_sectors < 2) throw ERR_BUFFER_TOO_SMALL;
    }
    
    
    // Initialises the meta data
    function init(cb = null) {
        if (!_loadMeta()) {
            // The meta data is invalid. Erase everything.
            erase(true, cb);
        } else if (cb) {
            cb();
        }
    }


    // Appends a buffer (blob) to the buffer
    function write(buffer) {
        
        if (!_began) throw ERR_BEGIN;
        
        local length = buffer.len();
        if (length > _free) {
            // Trim the buffer down to whatever size we have left
            // server.log(format("Trimming write buffer from %d to %d", length, _free));
            length = _free;
            buffer = buffer.readblob(length);
        }
        // server.log(format("Writing buffer length %d to spi from %d to %d", length, _start + _write_pos, _start + _write_pos + length))
        
        if (length > 0) {
            _enable();
            _flash.write(_data_start + _write_pos, buffer);
            _disable();
            
            _write_pos += length;
            _free -= length;
        }
        return length;
    }
    

    // Reads from the current seek position "length" bytes, stopping at the end of the buffer
    function read(length) {

        if (_read_pos + length >= _write_pos) {
            length = _write_pos - _read_pos;
        }
        if (length == 0) return null;
        
        _enable();
        local buffer = _flash.read(_data_start + _read_pos, length);
        _disable();
        
        _read_pos += length;
        return buffer;
        
    }
    
    
    // Seek to any point in the buffer, similar to blob seeking.
    function seek(offset, offsetBasis = 'b') {
        
        local new_pos = _read_pos;
        switch (offsetBasis) {
            case 'e':
                new_pos = _write_pos + offset;
                break;
            case 'c':
                new_pos += offset;
                break;
            case 'b':
                new_pos = offset
                break;
            default:
                throw ERR_INVALID_OFFSET;
        }
        
        // Now make the move if it is valid
        if (new_pos >= 0 || new_pos < _write_pos) {
            _read_pos = new_pos;
            return 0;
        } else {
            return -1;
        }
    }
    
    
    // Returns the raw size of the buffer
    function size() {
        return _size;
    }
    
    
    // Returns the number of free bytes in the buffer
    function free() {
        return _free;
    }
    

    // Returns the position of the write pointer, which is equal to the amount of the buffer already used
    function len() {
        return _write_pos;
    }
    
    
    // Returns the position of the read pointer
    function tell() {
        return _read_pos;
    }
        
    
    // Returns true if the read pointer is up to the write pointer, i.e. end of stream.
    function eos() {
        return _read_pos >= _write_pos;
    }
    
    
    // Returns true when the buffer is full and no more data can be written
    function eof() {
        return _free <= 0;
    }
    

    // Returns true of the buffer is busy doing something. Currently the only asynchronous function is erase().
    function busy() {
        return _erasing;
    }
    
    
    // Erases the dirty pages of the buffer. If the force parameter is true then erases all pages.
    // If a callback is supplied then the request is performed asynchronously
    function erase(force = false, finishedCallback = null) {

        // Allow for missing parameters
        if (typeof force == "function") {
            finishedCallback = force;
            force = false;
        }
        
        // Work out what we are erasing
        local old_write_pos = _write_pos;
        local from_s = 1, from = _data_start, to_s = null, to = null;
        if (force) {
            to_s = _sectors;
            to   = _end;
        } else if (_write_pos > 0) {
            to_s = (_data_start + _write_pos) / SPIFLASHBUFFER_SECTOR_SIZE;
            to   = _start + (to_s * SPIFLASHBUFFER_SECTOR_SIZE);
        }
        if (to != null) {
            // server.log(format("Erasing from %d (sector %d) to %d (sector %d)", from, from_s, to, to_s));
        }
        
        // Reset the position markers to epoch
        _read_pos = _write_pos = 0;
        _began = false;
        _free = _end - _data_start;
        
        if (finishedCallback) {
            // This is an async request
            local _erase;
            _erase = function (s) {
                
                // Check and erase this sector
                local sector = _start + (s * SPIFLASHBUFFER_SECTOR_SIZE);
                if (s < to_s) {
                    // server.log(format("Erasing %d (sector %d)", sector, s));
                    _enable();
                    _flash.erasesector(sector);
                    _disable();
                }
                
                // Move onto the next sector
                imp.wakeup(0, function() {
                    if (s+1 < to_s) {
                        _erase(s+1);
                    } else {
                        // All done
                        _buildMeta();
                        _erasing = false;
                        finishedCallback();
                    }
                }.bindenv(this))
            }
            
            // Start at the first non-meta sector (_meta_start)
            _erasing = true;
            _erase(1);

        } else {
            
            // This is a sync request
            _enable();
            for (local s = 1; s < to_s; s++) {
                local sector = _start + (s * SPIFLASHBUFFER_SECTOR_SIZE);
                // server.log(format("Erasing %d (sector %d)", sector, s));
                _flash.erasesector(sector);
            }
            _buildMeta();
            _disable();
            
        }
    }

    
    // All writes must be wrapped in begin/end transactions. Call begin() before any write.
    function begin() {
        // Write a dodgy length to mark the beginning of a transaction
        if (!_began) {
            _began = true;
            _enable();
            local length = blob(4);
            length.writen(SPIFLASHBUFFER_META_PARTIAL, 'i');
            _flash.write(_meta_start + _meta_len_pos, length);
            _disable();
        }
    }
    
    
    // All writes must be wrapped in begin/end transactions. Call end() after completed writing.
    // Once end() is executed the meta data is updated so using too many transactions will cause extra wear on the meta sector.
    function end() {
        if (_began) {
            
            _began = false;

            // Make sure we do not write over the end. 
            if (_meta_len_pos + 4 >= SPIFLASHBUFFER_SECTOR_SIZE) {
                
                // If we do, then read the header, erase underneath and rewrite the header
                _enable();
                local header = _flash.read(_meta_start, SPIFLASHBUFFER_META_SIZE);
                _buildMeta()
                _flash.write(_meta_start, header);
                _disable();

            }
            
            // Write the final length to mark the end of a transaction
            local length = blob(4);
            length.writen(_write_pos, 'i');
            _enable();
            _flash.write(_meta_start + _meta_len_pos, length);
            _disable();
            
            // Shuffle the length position forward 
            _meta_len_pos += 4;
            
        }
    }
    
    
    // Returns the dimensions of the buffer
    function dimensions() {
        return { "size": _size, "start": _start, "end": _end, "sectors": _sectors }
    }
    
    
    //-------------------- PRIVATE METHODS --------------------//

    // Enables the flash and prepares it for chatter
    function _enable() {
        if (_enables++ == 0) _flash.enable();
    }    

    
    // Disables the flash and allows it to power down
    function _disable() {
        if (--_enables == 0) _flash.disable();
    }    
    

    // Builds a new metadata block at the starting point
    function _buildMeta() {

        // This assumes the buffer has been fully erased
        // Write the magic and sector count to flash.
        local header = blob(SPIFLASHBUFFER_META_SIZE);
        header.writestring(SPIFLASHBUFFER_META_MAGIC); // Write the magic
        header.writen(_sectors, 'w'); // Write the sector count
        
        _enable();
        _flash.erasesector(_meta_start);
        _flash.write(_meta_start, header);
        _disable();
        
        // The current length can remain at default value (0xFF), so just reset the location of the length array
        _meta_len_pos = SPIFLASHBUFFER_META_SIZE;

        // server.log("New metadata created");

    }
    
    
    // Loads and parses the metadata at the starting point
    function _loadMeta() {
        
        /* The meta data structure is as follows:
        
        Length 5: Magic [SFBUF]
        Length 2: Sector count (16 bit unsigned integer)
        Until the end: Current length (4 bytes * x)
            Bit 0: Status (1 = clean, 0 = dirty)
            Bits 1-31: 32-bit integer length
            
        */
        
        _enable();
        local header = _flash.read(_meta_start, SPIFLASHBUFFER_META_SIZE);
        _disable();
        
        // Check the magic
        local magic = header.readstring(SPIFLASHBUFFER_META_MAGIC.len());
        if (magic != SPIFLASHBUFFER_META_MAGIC) {
            server.error(className + ": " + ERR_META_IS_INVALID);
            return false;            
        }
        
        // Check the sector count
        local sectors = header.readn('w');
        if (sectors != _sectors) {
            server.error(className + ": " + ERR_META_IS_INVALID);
            return false;
        }
        
        // Read the length map to the end of the meta sector
        _meta_len_pos = SPIFLASHBUFFER_META_SIZE;
        local length_len = SPIFLASHBUFFER_SECTOR_SIZE - (_meta_len_pos % SPIFLASHBUFFER_SECTOR_SIZE);
        _enable();
        local length_map = _flash.read(_meta_start + _meta_len_pos, length_len);
        _disable();
        
        _read_pos = _write_pos = 0;
        while (length_map.len() - length_map.tell() >= 4) {
            
            local new_write_pos = length_map.readn('i');
            if (new_write_pos == SPIFLASHBUFFER_META_PARTIAL) {
                // We have a half-written buffer. We have to discard this entire buffer.
                server.error(className + ": " + ERR_TRANSACTION_ABORTED);
                return false;
            } else if (new_write_pos == SPIFLASHBUFFER_META_FREE) {
                // We have no more write_pos values, stop reading and take the last value
                // server.log("Meta length is " + _write_pos + " from offset " + _meta_len_pos + " with " + _free + " bytes free");
                break;
            } else {
                // This is a valid write_pos, store it
                _write_pos = new_write_pos;
                _free = _end - _data_start - _write_pos;
                _meta_len_pos += 4;
            }
            
        }

        return true;
    }
}
