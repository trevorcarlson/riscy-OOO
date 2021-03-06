
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

import GetPut::*;
import Vector::*;
import FIFO::*;
import Clocks::*;
import Connectable::*;
import Types::*;
import ProcTypes::*;
import ProcIF::*;
import VerificationPacket::*;
import Performance::*;
import Core::*;
import SyncFifo::*;

// indication methods that are truly in use by processor
interface ProcIndInv;
    method ActionValue#(Tuple2#(CoreId, Data)) to_host;
    method ActionValue#(Tuple2#(CoreId, VerificationPacket)) debug_verify;
    method ActionValue#(Tuple2#(CoreId, ProcPerfResp)) perfResp;
    method ActionValue#(CoreId) terminate;
endinterface

instance Connectable#(ProcIndInv, ProcIndication);
    module mkConnection#(ProcIndInv inv, ProcIndication ind)(Empty);
        rule doToHost;
            let {c, v} <- inv.to_host;
            ind.to_host(zeroExtend(c), v);
        endrule
        rule doVerify;
            let {c, v} <- inv.debug_verify;
            ind.debug_verify(zeroExtend(c), v);
        endrule
        rule doPerf;
            let {c, p} <- inv.perfResp;
            ind.perfResp(zeroExtend(c), p);
        endrule
        rule doTerminate;
            let c <- inv.terminate;
            ind.terminate(zeroExtend(c));
        endrule
    endmodule
endinstance

// this module should be under user clock domain
module mkProcIndInvSync#(Vector#(CoreNum, CoreIndInv) inv, Clock portalClk, Reset portalRst)(ProcIndInv);
    Clock userClk <- exposeCurrentClock;
    Reset userRst <- exposeCurrentReset;
    SyncFIFOIfc#(Tuple2#(CoreId, Data)) hostQ <- mkSyncFifo(1, userClk, userRst, portalClk, portalRst);
    SyncFIFOIfc#(Tuple2#(CoreId, VerificationPacket)) verifyQ <- mkSyncFifo(1, userClk, userRst, portalClk, portalRst);
    SyncFIFOIfc#(Tuple2#(CoreId, ProcPerfResp)) perfQ <- mkSyncFifo(1, userClk, userRst, portalClk, portalRst);
    SyncFIFOIfc#(CoreId) terminateQ <- mkSyncFifo(1, userClk, userRst, portalClk, portalRst);

    for(Integer i = 0; i < valueof(CoreNum); i = i+1) begin
        rule sendHost;
            let v <- inv[i].to_host;
            hostQ.enq(tuple2(fromInteger(i), v));
        endrule
        rule sendVerify;
            let v <- inv[i].debug_verify;
            verifyQ.enq(tuple2(fromInteger(i), v));
        endrule
        rule sendPerf;
            let v <- inv[i].perfResp;
            perfQ.enq(tuple2(fromInteger(i), v));
        endrule
        rule sendTerminate;
            let v <- inv[i].terminate;
            terminateQ.enq(fromInteger(i));
        endrule
    end

    method to_host = toGet(hostQ).get;
    method debug_verify = toGet(verifyQ).get;
    method perfResp = toGet(perfQ).get;
    method terminate = toGet(terminateQ).get;
endmodule

// request methods that are truly in use by processor
interface ProcReq;
    method Action start(Bit#(64) pc, Bool ipi_wait_msip_zero, Bit#(64) pack_ignore, Bool sync_pack); // broadcase to all cores
    method Action from_host(Bit#(8) core, Bit#(64) v);
    method Action perfReq(Bit#(8) core, PerfLocation loc, PerfType t);
endinterface

// this module should be under user clock domain
module mkProcReqSync#(
    Vector#(CoreNum, CoreReq) req, Clock portalClk, Reset portalRst
)(ProcReq);
    Clock userClk <- exposeCurrentClock;
    Reset userRst <- exposeCurrentReset;
    SyncFIFOIfc#(Tuple4#(Bit#(64), Bool, Bit#(64), Bool)) startQ <- mkSyncFifo(1, portalClk, portalRst, userClk, userRst);
    SyncFIFOIfc#(Tuple2#(CoreId, Bit#(64))) hostQ <- mkSyncFifo(1, portalClk, portalRst, userClk, userRst);
    SyncFIFOIfc#(Tuple3#(CoreId, PerfLocation, PerfType)) perfQ <- mkSyncFifo(1, portalClk, portalRst, userClk, userRst);

    rule doStart;
        let {pc, ipi_wait, ignore, sync} <- toGet(startQ).get;
        for(Integer i = 0; i < valueof(CoreNum); i = i+1) begin
            req[i].start(pc, ipi_wait, ignore, sync);
        end
    endrule
    rule doHost;
        hostQ.deq;
        let {c, v} = hostQ.first;
        req[c].from_host(v);
    endrule
    rule doPerf;
        perfQ.deq;
        let {c, loc, t} = perfQ.first;
        req[c].perfReq(loc, t);
    endrule

    method Action start(Bit#(64) pc, Bool ipi_wait_msip_zero, Bit#(64) pack_ignore, Bool sync_pack);
        startQ.enq(tuple4(pc, ipi_wait_msip_zero, pack_ignore, sync_pack));
    endmethod
    method Action from_host(Bit#(8) core, Bit#(64) v);
        hostQ.enq(tuple2(truncate(core), v));
    endmethod
    method Action perfReq(Bit#(8) core, PerfLocation loc, PerfType t);
        perfQ.enq(tuple3(truncate(core), loc, t));
    endmethod
endmodule
