
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

#include "proc_ind.h"

ProcIndication::ToHostHandler::ToHostHandler(ProcIndication *p_ind) :
    msg_q_size(0),
    proc_ind(p_ind)
{
}

ProcIndication::ToHostHandler::~ToHostHandler() {
    if(handler_thread.joinable()) {
        handler_thread.join();
    }
}

void ProcIndication::ToHostHandler::enq_to_host_msg(uint32_t core, uint64_t v) {
    std::lock_guard<std::mutex> lock(msg_q_mu);
    ToHostMsg msg;
    msg.core = core;
    msg.v = v;
    to_host_msg_q.push(msg);
    msg_q_size.fetch_add(1);
}

void ProcIndication::ToHostHandler::handler() {
    while(1) {
        // first spin to get one msg to process
        while(msg_q_size.load() == 0);

        bool msg_valid = false;
        ToHostMsg msg;
        {
            std::lock_guard<std::mutex> lock(msg_q_mu);
            if(!to_host_msg_q.empty()) {
                msg_valid = true;
                msg = to_host_msg_q.front();
                to_host_msg_q.pop();
                msg_q_size.fetch_sub(1);
            }
        }

        // process msg
        if(msg_valid) {
            uint64_t v = msg.v;
            {
                // normal processing of HTIF msg, need to lock htif
                proc_ind->riscy_htif->lock();
                if (v == 0) {
                    // ignore writing 0 to to_host
                    fprintf(stderr, "[to_host] ignoring write to to_host\n");
                    proc_ind->riscy_htif->write_cr(msg.core, CSR_MFROMHOST, 0);
                } else {
                    // send all non-zero writes to the htif
                    proc_ind->riscy_htif->get_to_host(msg.core, v);
                }
                bool htif_done = false;
                int exit_code = 0;
                if (proc_ind->riscy_htif->done()) {
                    htif_done = true;
                    exit_code = proc_ind->riscy_htif->exit_code();
                }
                proc_ind->riscy_htif->unlock();

                //fprintf(stderr, "[ProcIndication] to_host(%llx) done\n", (long long)v); 

                if(htif_done) {
                    {
                        std::lock_guard<std::mutex> lock(proc_ind->proc_mu);
                        proc_ind->done = true;
                        proc_ind->result = exit_code;
                        if (proc_ind->error_found) {
                            // print output_buff
                            proc_ind->print_buff->flush_print();
                        }
                    }
                    if(exit_code == 0) {
                        fprintf(stderr, "[32;1mPASSED[0m\n");
                    }
                    else {
                        fprintf(stderr, "[31;1mFAILED %lld[0m\n", (long long)exit_code);
                    }
                    sem_post(&(proc_ind->sem)); // notify program finish
                    return; // exit thread
                }
            }
        }
    }
}

void ProcIndication::ToHostHandler::spawn_handler_thread() {
    handler_thread = std::thread(&ProcIndication::ToHostHandler::handler, this);
}
