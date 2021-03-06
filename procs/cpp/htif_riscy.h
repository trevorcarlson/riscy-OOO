
// Copyright (c) 2017 Massachusetts Institute of Technology
// 
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

// See LICENSE for license details.
// This was modified from htif.h in spike
#ifndef _HTIF_RISCY_H
#define _HTIF_RISCY_H

#include <functional>
#include <mutex>
#include "fesvr/htif.h"

struct packet;

class htif_riscy_t: public htif_t
{
public:
    // callbacks to access RISCV proc memory on FPGA
    typedef std::function<void(addr_t, size_t, void*)> DmaReadFunc;
    typedef std::function<void(addr_t, size_t, const void*)> DmaWriteFunc;
    // callback function to use to write to mfromhost
    typedef std::function<void(uint32_t, reg_t)> WriteFromHostFunc;

    htif_riscy_t(const std::vector<std::string>& args, uint32_t _core_num);

    reg_t read_cr(uint32_t coreid, uint16_t regnum);
    reg_t write_cr(uint32_t coreid, uint16_t regnum, reg_t val);

    //// Riscy code ////
    // set memory size
    void set_mem_size(size_t mem_size) { memsz = mem_size; }
    // set callback func for DMA
    void set_dma_read(DmaReadFunc f) { dma_read = f; }
    void set_dma_write(DmaWriteFunc f) { dma_write =f; }
    // set callback for writing mfromhost
    void set_write_from_host(WriteFromHostFunc f) { write_from_host = f; }
    // called whenever a message is sent from the host
    void get_to_host(uint32_t coreid, reg_t x);
    // stdin
    bool bcd_wait_for_stdin();
    void bcd_feed_stdin(int ch); // [sizhuo] feed bcd with stdin or 0
    ////////////////////

    void lock() { htif_lock.lock(); }
    void unlock() { htif_lock.unlock(); }

protected:
    void read_chunk(addr_t taddr, size_t len, void* dst);
    void write_chunk(addr_t taddr, size_t len, const void* src);

    size_t chunk_align() { return sizeof(uint64_t); }
    size_t chunk_max_size() {
        return (sizeof(uint64_t) * 256); // XXX AXI limit on burst len
    }
    ssize_t read(void* buf, size_t max_size) { return 0; }
    ssize_t write(const void* buf, size_t size) { return 0; }

private:
    // processor num
    uint32_t core_num;
    // RISCV proc memory
    size_t memsz; // number of bytes in mem
    DmaReadFunc dma_read;
    DmaWriteFunc dma_write;
    // write MFROMHOST
    WriteFromHostFunc write_from_host;

    const bool verbose;

    // lock for multithread
    std::mutex htif_lock;
};

#endif
