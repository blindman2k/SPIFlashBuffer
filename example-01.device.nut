// This is a fairly comprehensive example application designed for use on the imp003-evb.
// It includes a full audio buffer for recording and playback.

#require "SPIFlashBuffer.class.nut:1.0.0"
#require "Button.class.nut:1.1.1"

//==============================================================================
class BufferedAudio {
    
    _buffer = null;
    
    _pin_mic = null;
    _pin_mic_en_l = null;
    _pin_spk = null;
    _pin_spk_en = null;
    
    _freq_m = null;
    _freq_s = null;
    
    _bfr_m_len = null;
    _bfr_s_len = null;
    _bfr_m_cnt = null;
    _bfr_s_cnt = null;
    
    _flags_m = null;
    _flags_s = null;
    
    _playing = false;
    _recording = false;
    _play_stopped = false;
    _record_stopped = false;
    
    
    //--------------------------------------------------------------------------
    constructor(buffer) {
        _buffer = buffer;
    }
    
    //--------------------------------------------------------------------------
    function sampler(inputPin, enablePin = null, freq = 16000, bufferSize = 4096, bufferCount = 3, flags = NORMALISE | A_LAW_COMPRESS) {

        _pin_mic = inputPin;
        _pin_mic_en_l = enablePin;
        _freq_m   = freq;
        _bfr_m_len = bufferSize;
        _bfr_m_cnt = bufferCount;
        _flags_m = flags;
        
        if (_pin_mic_en_l) _pin_mic_en_l.configure(DIGITAL_OUT, 1);
        return this;
    }
    
    
    //--------------------------------------------------------------------------
    function record(finishedCallback, maxDuration = null) {
        
        // Make sure the sampler() configuration function has been called
        if (!_pin_mic) {
            if (finishedCallback) finishedCallback("Not configured", 0);
            else server.error("Can't start recording, not configured")
            return;
        }
        
        // Make sure nothing else is already recording
        if (_recording) {
            if (finishedCallback) finishedCallback("Busy", 0);
            else server.error("Can't start recording, sampler is busy")
            return;
        }
        
        // Do we have space?
        if (_buffer.eof()) {
            if (finishedCallback) finishedCallback("No free space", 0);
            else server.error("The audio buffer is full")
            return;
        }
        
        // Setup the buffers
        local buffers = [];
        for (local b = 0; b < _bfr_m_cnt; b++) {
            buffers.push(blob(_bfr_m_len));
        }

        // Setup a buffer handler
        local total = 0;
        local _bufferDone = function(buffer, length) {
    
            if (length == 0) {
                // Overrun
                server.error("Buffer overrun");
            } else {
                // Buffer ready, write it
                local written = _buffer.write(buffer.readblob(length));
                total += written;

                if (_buffer.eof()) {
                    // We have filled the buffer. Stop now.
                    stopRecording();
                }
            } 
            
            if (_record_stopped) {
                // Finished recording
                if (_recording != true && _recording != false) imp.cancelwakeup(_recording);
                _recording = _record_stopped = false;
                hardware.sampler.reset();
                _buffer.end();
                if (finishedCallback) {
                    imp.wakeup(0, function() {
                        finishedCallback(null, total);
                    }.bindenv(this))
                }
            }
            
        }.bindenv(this)

        // Start the sampler        
        if (_pin_mic_en_l) _pin_mic_en_l.write(0);
        hardware.sampler.configure(_pin_mic, _freq_m, buffers, _bufferDone, _flags_m);
        hardware.sampler.start();
        _buffer.begin();
        _record_stopped = false;

        if (maxDuration) {
            // Automatically stop   
            _recording = imp.wakeup(maxDuration, stopRecording.bindenv(this));
        } else {
            _recording = true;
        }
    }
    
    
    //--------------------------------------------------------------------------
    function stopRecording() {

        if (_recording) {
            // Stop the recording
            hardware.sampler.stop();
            if (_pin_mic_en_l) _pin_mic_en_l.write(1);
            _record_stopped = true;
            if (_recording != true) imp.cancelwakeup(_recording);
        }
    }

    
    //--------------------------------------------------------------------------
    function player(outputPin, enablePin = null, freq = 16000, bufferSize = 4096, bufferCount = 3, flags = AUDIO | A_LAW_DECOMPRESS) {

        _pin_spk = outputPin;
        _pin_spk_en = enablePin;
        _freq_s = freq;
        _bfr_s_len = bufferSize;
        _bfr_s_cnt = bufferCount;
        _flags_s = flags;
        
        if (_pin_spk_en) _pin_spk_en.configure(DIGITAL_OUT, 0);
        return this;
    }
    
    
    //--------------------------------------------------------------------------
    function play(start = null, finish = null, finishedCallback = null) {
        
        // Make sure the player() configuration function has been called
        if (!_pin_spk) {
            if (finishedCallback) finishedCallback("Not configured", 0);
            else server.error("Can't start playing, not configured")
            return;
        }
        
        // Make sure nothing else is already playing
        if (_playing) {
            if (finishedCallback) finishedCallback("Busy", 0);
            else server.error("Can't start playing, player is busy")
            return;
        }
        
        // Shuffle the optional parameters
        if (typeof finish == "function") {
            finishedCallback = finish;
            finish = null;
        }
        if (typeof start == "function") {
            finishedCallback = start;
            finish = start = null;
        }
        
        if (start == null || start < 0) start = 0;
        else if (start > _buffer.len()) start = _buffer.len();
        if (finish == null || finish > _buffer.len()) finish = _buffer.len();
        
        // Make sure we have actually something to play
        local bytes = finish - start;
        if (bytes <= 0) {
            if (finishedCallback) finishedCallback("Zero bytes", 0);
            else server.error("You have asked to play 0 bytes")
            return;
        }
        
        local bufferedBytes = 0;
        local buffers = [];
        local buffer = null;
        
        // Setup the buffers
        _buffer.seek(start);
        for (local b = 0; b < _bfr_s_cnt; b++) {
            local length = _bfr_s_len;
            if (bufferedBytes + _bfr_s_len >= bytes) {
                length = bytes - bufferedBytes;
            }
            if (length > 0) {

                local tell = _buffer.tell();
                buffer = _buffer.read(length);
                if (buffer) {
                    bufferedBytes += length;
                    server.log(format("Added %d bytes from %d for a total of %d/%d bytes", length, tell, bufferedBytes, bytes));
                    buffers.push(buffer);
                } else {
                    server.log(format("Failed to add %d bytes from %d for a total of %d/%d bytes", length, tell, bufferedBytes, bytes));
                    break;
                }
            }
        }

        // Make sure we have actually read something into the buffers
        if (buffers.len() == 0) {
            if (finishedCallback) finishedCallback("Empty buffer", 0);
            else server.error("You have asked to play an empty buffer")
            return;
        }
        
        local _bufferDone = function(buffer) {
    
            if (_play_stopped) {
                // Play has stopped, don't hand over any more data
            } else if (buffer == null) {
                // Underrun
                server.error("Buffer underrun");
            } else {
                
                // Ready for next buffer
                local length = _bfr_s_len;
                if (bufferedBytes + _bfr_s_len >= bytes) {
                    length = bytes - bufferedBytes;
                }
                
                if (length > 0) {
                
                    local tell = _buffer.tell();
                    buffer = null;
                    buffer = _buffer.read(length);

                    hardware.fixedfrequencydac.addbuffer(buffer);
                    bufferedBytes += length;
                    
                    server.log(format("Added %d bytes from %d for a total of %d/%d bytes", length, tell, bufferedBytes, bytes));
                }

                if (bufferedBytes >= bytes) {
                    
                    // We have drained the buffer. Stop now.
                    _play_stopped = true;
                }
            } 
            
            if (_play_stopped && buffer == null) {
                // Finished playing
                _playing = _play_stopped = false;
                hardware.fixedfrequencydac.stop();
                if (_pin_spk_en) _pin_spk_en.write(0);
                if (finishedCallback) {
                    imp.wakeup(0, function() {
                        finishedCallback(null, bytes);
                    })
                }
            }
            
        }.bindenv(this)

        // Start the DAC        
        hardware.fixedfrequencydac.configure(_pin_spk, _freq_s, buffers, _bufferDone, _flags_s);
        hardware.fixedfrequencydac.start();
        if (_pin_spk_en) _pin_spk_en.write(1);
        _play_stopped = false;
        _playing = true;

    }
    
    
    //--------------------------------------------------------------------------
    function stopPlaying() {

        if (_playing) {
            // Stop the playback
            if (_pin_spk_en) _pin_spk_en.write(0);
            _play_stopped = true;
        }
    }


    // -------------------------------------------------------------------------
    function busy() {
        return _recording || _playing || _buffer.busy();
    }
    
}



//==============================================================================

// Allocate 100 x 4k sectors which is about 25s of audio at 16k per second.
sfb <- SPIFlashBuffer(0 * SPIFLASHBUFFER_SECTOR_SIZE, 100 * SPIFLASHBUFFER_SECTOR_SIZE);
audio <- BufferedAudio(buffer);

// Setup the pins per the imp003-evb. These can easily be replaced with other pins
audio.sampler(hardware.pinJ, hardware.pinT);
audio.player(hardware.pinC, hardware.pinS);

button1 <- Button(hardware.pinU, DIGITAL_IN_PULLDOWN, Button.NORMALLY_LOW);
button2 <- Button(hardware.pinV, DIGITAL_IN_PULLDOWN, Button.NORMALLY_LOW);

// Handle the button presses
button1
.onPress(
	function() {

	    if (!audio.busy()) {
	        server.log("========[ Recording ]=========")
	        local started = hardware.millis();
	        audio.record(function(err, bytes) {
	            local dur = (hardware.millis() - started) / 1000.0;
	            if (err) server.log("Error recording: " + err);
	            else     server.log(format("Recording ended after %0.2fs (%d bytes). Buffer size is now %d bytes", dur, bytes, buffer.len()));
	            server.log("========[ Done ]=========\n\n")
	        })
	    }

	    
	}
)
.onRelease(
	function() {

	    if (audio.busy()) {
	        audio.stopRecording();
	    }

	}
)


button2
.onPress(
	function() {	    
	    if (buffer.len() > 0 && !audio.busy()) {
	        server.log("========[ Playing ]=========")
	        audio.play(function(err, bytes) {
	            if (err) server.log("Error playing: " + err);
	            else     server.log(format("Playback ended after %d bytes read", bytes));
	            server.log("========[ Done ]=========\n\n")

                server.log("========[ Erasing ]=========")
                buffer.erase();
                server.log("========[ Done ]=========\n\n")
            
	        });
	    }
	}
)
.onRelease(
	function() {
        if (audio.busy()) {
            audio.stopPlaying();
        } 
    }
)


//..............................................................................
server.log("Ready. Press button 1 to record or button 2 to play and then erase.")
