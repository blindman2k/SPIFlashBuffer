# SPIFlashBuffer 1.0.0

The SPIFlashBuffer (SFB) library implements a single blob buffer for quickly recording a stream of data into a SPI Flash device (using either the built-in [hardware.spiflash](https://electricimp.com/docs/api/hardware/spiflash) object on imp003+, or an external SPI Flash plus the [SPIFlash library](https://github.com/electricimp/spiflash) on the imp001 and imp002). It is particularly suited to recording audio using the imp's [sampler](https://electricimp.com/docs/api/hardware/sampler).

**To add this library to your project, add `#require "SPIFlashBuffer.class.nut:1.0.0"`` to the top of your device code.**

You can view the library’s source code on [GitHub](https://github.com/electricimp/SPIFlashBuffer/tree/v1.0.0).

## Overview of the File System

The first 4kb sector of the SPI flash allocation holds the meta data. The meta data contains a marker token, the number of sectors being managed and the length of the buffer. Every time the buffer is written to (appended to) a new length is appended to the end of the metadata. When the meta sector is full, it is erased and the new length is written at the beginning. Writes are wrapped in begin/end transactions to reduce the number of times the metadata is written to and therebye reduces the number of times it is erased.


# SPIFlashBuffer

### Constructor: SPIFlashBuffer(*[start, end, spiflash]*)

The SPIFlashBuffer constructor allows you to specify the start and end bytes of the file system in the SPIFlash, as well as an optional SPIFlash object (if you are not using the built in `hardware.spiflash` object).

The start and end values **must** be on sector boundaries (0x1000, 0x2000, ...), otherwise a `SPIFlashBuffer.ERR_INVALID_BOUNDARY` error will be thrown. 

#### imp003+
```squirrel
#require "SPIFlashBuffer.class.nut:1.0.0"

// Allocate the first 100 pages (400kb) of the SPI flash to a buffer
sfb <- SPIFlashBuffer(0x00, 0x400000);
sfb.init();

```

#### imp001 / imp002
```squirrel
#require "SPIFlash.class.nut:1.0.1"
#require "SPIFlashBuffer.class.nut:1.0.0"

// Configure the external SPIFlash
flash <- SPIFlash(hardware.spi257, hardware.pin8);
flash.configure(500000);

// Allocate the first 100 pages (400kb) of the SPI flash to a buffer
sfb <- SPIFlashBuffer(0x00, 0x400000);
```

## Class Methods

### write(object)

The *write* function appends the provided blob to the end of the buffer and updates the meta data. It must be wrapped in a begin/end transaction. 

```squirrel
local data = blob();
data.writestring("Hello, world.");

sfb.begin();
sfb.write(data);
sfb.end();
```


### read(*length*)

The *read* function returns the next *length* bytes from the current location in the buffer. It progresses an internal pointer forward so that subsequent reads will return the next part of the buffer like a file.

```squirrel
local data = sfb.read(100);
server.log(format("The data stored is a %s, containing: %s", typeof data, data.tostring()))
```


### seek(*offset [, offsetBasis='b']*)

Moves the read pointer to a new location. The offset is in bytes and the offsetBasis is one of 'b' = beginning (default), 'c' = current or 'e' = end.

```squirrel
// This is how you read the same bytes twice.
sfb.seek(0, 'b');
local data = sfb.read(100);
sfb.seek(0, 'b');
data = sfb.read(100);
```

### tell()

tell() reports the current position of the read pointer in the buffer.

```squirrel
local data = sfb.read(1024);
server.log("Position should be 1024: " + sfb.tell())
sfb.seek(100);
server.log("Position should be 100: " + sfb.tell())
sfb.seek(100, 'c');
server.log("Position should be 200: " + sfb.tell())
```


### erase(*force=false [, callback]*)

Erases all the sectors from the start to the current write position. If force is set to true then it erases all the sectors from the start to end.
If a callback is provided then the operation is performed asynchonously and the callback is fired at the completion. Otherwise the erase operation is called sychronously.

```squirrel
sfb.erase();
```


### begin()
### end()

Starts and ends a write operation. You must call begin() before writing and you should call end when you have finished writing. There is no minimum or maximum amount of time between begin() and end() but if you leave a transaction open then you can consider the whole buffer to be at risk after a reboot. If a transaction is incomplete after a reboot then the initialisation function will wipe the entire buffer.

```squirrel
local data = blob(100);
sfb.begin();
for (local i = 0; i < 100; i++) {
	sfb.write(data);
}
sfb.end();
```


### eof()
### eos()

eof() reports true when no more writes are possible. eos() reports true when no more reads are possible.

```squirrel

// Write till the storage is full
local data = blob(1024);
sfb.begin();
while (!sfb.eof()) {
	sfb.write(data);
}
sfb.end();

// Now read it all back out
local data = null;
sfb.seek(0);
while (!sfb.eos()) {
	data = sfb.read(1024);
}
```

### len()

len() reports the total number of bytes written to the buffer so far.

```squirrel
local data = blob(1024);
sfb.begin();
sfb.write(data);
sfb.end();
server.log("Bytes written: " + sfb.len())
```



# TODO:
- Take the read pointer out of the buffer, like is done in SPIFlashFileSystem with open().
- Randomly locate the meta sector after every erase to reduce wear. Use the meta data magic as the start indicator
- Optionally wrap around to the start instead of ending recording
- Add a function for copying the contents out to a SPIFlashFileSystem object



# License

The SPIFlash class is licensed under [MIT License](./LICENSE).
