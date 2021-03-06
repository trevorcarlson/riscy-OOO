
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

`include "ProcConfig.bsv"
import Vector::*;
import GetPut::*;
import Cntrs::*;
import Fifo::*;
import FIFO::*;
import Types::*;
import ProcTypes::*;
import CCTypes::*;
import SynthParam::*;
import Performance::*;
import Exec::*;
import FetchStage::*;
import RenamingTable::*;
import ReorderBuffer::*;
import ReorderBufferSynth::*;
import Scoreboard::*;
import ScoreboardSynth::*;
import CsrFile::*;
import SpecTagManager::*;
import EpochManager::*;
import ReservationStationEhr::*;
import ReservationStationAlu::*;
import ReservationStationMem::*;
import ReservationStationFpuMulDiv::*;
import SpecLSQ::*;

typedef struct {
    FetchDebugState fetch;
    EpochDebugState epoch;
    Bool htifStall;
} RenameStuck deriving(Bits, Eq, FShow);

interface RenameInput;
    // func units
    interface FetchStage fetchIfc; // just for debug
    interface ReorderBufferSynth robIfc;
    interface RegRenamingTable rtIfc;
    interface ScoreboardCons sbConsIfc;
    interface ScoreboardAggr sbAggrIfc;
    interface CsrFile csrfIfc;
    interface EpochManager emIfc;
    interface SpecTagManager smIfc;
    interface Vector#(AluExeNum, ReservationStationAlu) rsAluIfc;
    interface ReservationStationFpuMulDiv rsFpuMulDivIfc;
    interface ReservationStationMem rsMemIfc;
    interface SpecLSQ lsqIfc;
    // htif
    method Bool isHtifStall;
    // not flushing pipeline by recv host msg or ipi
    method Bool notFlushingPipe;
    // deadlock check
    method Bool checkDeadlock;
    // performance
    method Bool doStats;
endinterface

interface RenameStage;
    // performance count
    method Data getPerf(ExeStagePerfType t);
    // deadlock check
    interface Get#(RenameStuck) renameInstStuck;
    interface Get#(RenameStuck) renameCorrectPathStuck;
endinterface

module mkRenameStage#(RenameInput inIfc)(RenameStage);
    Bool verbose = True;

    // func units
    FetchStage fetchStage = inIfc.fetchIfc;
    ReorderBufferSynth rob = inIfc.robIfc;
    RegRenamingTable regRenamingTable = inIfc.rtIfc;
    ScoreboardCons sbCons = inIfc.sbConsIfc;
    ScoreboardAggr sbAggr = inIfc.sbAggrIfc;
    CsrFile csrf = inIfc.csrfIfc;
    EpochManager epochManager = inIfc.emIfc;
    SpecTagManager specTagManager = inIfc.smIfc;
    Vector#(AluExeNum, ReservationStationAlu) reservationStationAlu;
    for(Integer i = 0; i < valueof(AluExeNum); i = i+1) begin
        reservationStationAlu[i] = inIfc.rsAluIfc[i];
    end
    ReservationStationFpuMulDiv reservationStationFpuMulDiv = inIfc.rsFpuMulDivIfc;
    ReservationStationMem reservationStationMem = inIfc.rsMemIfc;
    SpecLSQ lsq = inIfc.lsqIfc;

    // performance counter
`ifdef PERF_COUNT
    Count#(Data) supRenameCnt <- mkCount(0);
`endif

    // deadlock check
`ifdef CHECK_DEADLOCK
    // timer to check deadlock
    Reg#(DeadlockTimer) renameInstTimer <- mkReg(0);
    Reg#(DeadlockTimer) renameCorrectPathTimer <- mkReg(0);
    // FIFOs to output deadlock info
    FIFO#(RenameStuck) renameInstStuckQ <- mkFIFO1;
    FIFO#(RenameStuck) renameCorrectPathStuckQ <- mkFIFO1;
    // wires to indicate that deadlock is reported, so reset timers
    PulseWire renameInstStuckSent <- mkPulseWire;
    PulseWire renameCorrectPathStuckSent <- mkPulseWire;
    // wires to reset timers since processor is making progress
    PulseWire renameWrongPath <- mkPulseWire;
    PulseWire renameCorrectPath <- mkPulseWire;

    let renameStuck = RenameStuck {
        fetch: fetchStage.getFetchState,
        epoch: epochManager.getEpochState,
        htifStall: inIfc.isHtifStall
    };

    (* fire_when_enabled *)
    rule checkDeadlock_renameInst(inIfc.checkDeadlock && renameInstTimer == maxBound);
        renameInstStuckQ.enq(renameStuck);
        renameInstStuckSent.send;
    endrule

    (* fire_when_enabled *)
    rule checkDeadlock_renameCorrecPath(inIfc.checkDeadlock && renameCorrectPathTimer == maxBound);
        renameCorrectPathStuckQ.enq(renameStuck);
        renameCorrectPathStuckSent.send;
    endrule

    (* fire_when_enabled, no_implicit_conditions *)
    rule incrDeadlockTimer(inIfc.checkDeadlock);
        function DeadlockTimer getNextTimer(DeadlockTimer t);
            return t == maxBound ? maxBound : t + 1;
        endfunction
        renameInstTimer <= (renameCorrectPath || renameWrongPath || renameInstStuckSent) ? 0 : getNextTimer(renameInstTimer);
        renameCorrectPathTimer <= (renameCorrectPath || renameCorrectPathStuckSent) ? 0 : getNextTimer(renameCorrectPathTimer);
    endrule
`endif

    // kill wrong path inst
    // XXX we have to make this a separate rule instead of merging it with rename correct path
    // This is because the rename correct path rule is conflict with other rules that redirect
    // If wrong path inst keeps coming in, the rename rule may only kill wrong path, but blocks the redirect rule
    rule doRenaming_wrongPath(
        !inIfc.isHtifStall && inIfc.notFlushingPipe // stall when flushing pipeline
        && !epochManager.checkEpoch[0].check(fetchStage.pipelines[0].first.main_epoch) // first wrong path, so at least kill one
    );
        // we stop when we see a correct path inst
        Bool stop = False;
        for(Integer i = 0; i < valueof(SupSize); i = i+1) begin
            if(!stop && fetchStage.pipelines[i].canDeq) begin
                let x = fetchStage.pipelines[i].first;
                if(epochManager.checkEpoch[i].check(x.main_epoch)) begin
                    // correct path; stop killing
                    stop = True;
                end
                else begin
                    // wrong path, kill it & update prev epoch
                    fetchStage.pipelines[i].deq;
                    epochManager.updatePrevEpoch[i].update(x.main_epoch);
                    if(verbose) $display("[doRenaming - %d] wrong path: pc = %16x", i, x.pc);
                end
            end
        end
`ifdef CHECK_DEADLOCK
        renameWrongPath.send;
`endif
    endrule

    // check for exceptions and interrupts
    function Maybe#(Trap) getTrap(FromFetchStage x);
        Maybe#(Trap) trap = tagged Invalid;
        let csr_state = csrf.csrState;
        let pending_interrupt = csrf.pending_interrupt;
        let new_exception = checkForException(x.dInst, x.regs, csr_state);
        if (isValid(x.cause)) begin
            // previously found exception
            trap = tagged Valid (tagged Exception fromMaybe(?, x.cause));
        end else if (isValid(pending_interrupt)) begin
            // pending interrupt
            trap = tagged Valid (tagged Interrupt fromMaybe(?, pending_interrupt));
        end else if (isValid(new_exception)) begin
            // newly found exception
            trap = tagged Valid (tagged Exception fromMaybe(?, new_exception));
        end
        return trap;
    endfunction

    // trap for first inst to rename
    Maybe#(Trap) firstTrap = getTrap(fetchStage.pipelines[0].first);

    // XXX Stall renaming till ROB is empty if we need to replay this inst (i.e. system inst)
    // This is a rough fix for a bug with the FPU CSR registers.
    // i.e. stall when doReplay(inst) is true

    function Action incrEpochWithoutRedirect;
    action
        epochManager.incrementEpochWithoutRedirect;
        // stall fetch until redirect
        fetchStage.setWaitRedirect;
    endaction
    endfunction

    // rename single trap
    rule doRenaming_Trap(
        !inIfc.isHtifStall && inIfc.notFlushingPipe // stall when flushing pipeline
        && epochManager.checkEpoch[0].check(fetchStage.pipelines[0].first.main_epoch) // correct path
        && isValid(firstTrap) // take trap
    );
        fetchStage.pipelines[0].deq;
        let x = fetchStage.pipelines[0].first;
        let pc = x.pc;
        let ppc = x.ppc;
        let main_epoch = x.main_epoch;
        let dpTrain = x.dpTrain;
        let inst = x.inst;
        let dInst = x.dInst;
        let arch_regs = x.regs;
        let cause = x.cause;
        if(verbose) $display("[doRenaming] trap: ", fshow(x));

        // this may be system inst, stall for ROB empty
        when(!doReplay(dInst.iType) || rob.isEmpty, noAction);
        // update prev epoch
        epochManager.updatePrevEpoch[0].update(main_epoch);
        // Flip epoch without redirecting
        // This avoids doing incorrect work
        incrEpochWithoutRedirect;
        // just place it in the reorder buffer
        let y = ToReorderBuffer{pc: pc,
                                iType: dInst.iType,
                                csr: dInst.csr,
                                claimed_phy_reg: False, // no renaming is done
                                trap: firstTrap,
                                // default values of FullResult
                                ppc_vaddr_csrData: PPC (ppc), // default use PPC
                                fflags: 0,
                                ////////
                                will_dirty_fpu_state: False,
                                rob_inst_state: Executed,
                                spec_bits: specTagManager.currentSpecBits,
                                spec_tag: Invalid // epoch incremeneted, no need for spec tag 
`ifdef VERIFICATION_PACKETS
                                , inst: inst
                                , arch_reg_dst: Invalid
                                , result_data: 0 // default val of FullResult
`endif
                               };
        rob.enqPort[0].enq(y);
`ifdef CHECK_DEADLOCK
        renameCorrectPath.send;
`endif
    endrule


    // rename correct path inst
    rule doRenaming(
        !inIfc.isHtifStall && inIfc.notFlushingPipe // stall when flushing pipeline
        && epochManager.checkEpoch[0].check(fetchStage.pipelines[0].first.main_epoch) // correct path
        && !isValid(firstTrap) // not trap
    );
        // we stop superscalar rename after
        // 1. epoch incremented (system inst)
        //    - This makes epochManager up-to-date when checking wrong path inst
        // 2. an instruction cannot be processed when
        //    (a) It has trap
        //    (b) It is wrong path
        //    (c) It is system inst, but not the first inst (we delay this inst to next cycle)
        //        because system inst need to wait all previous inst commit from ROB
        //    (d) It does not have enough resource
        Bool stop = False;
        // We automatically stop after an inst cannot be deq from fetch stage
        // because canDeq signal for sup-fifo is consecutive

        // track limited resource usage
        Vector#(AluExeNum, Bool) aluExeUsed = replicate(False);
        Bool fpuMulDivExeUsed = False;
        Bool memExeUsed = False;
        Bool specTagClaimed = False; // specTagManager

        // track rename activity
        Bool doCorrectPath = False;
        SupCnt renameCnt = 0;

        // initial spec bits at the beginning of this cycle
        // we may update it during the processing
        SpecBits spec_bits = specTagManager.currentSpecBits;

        // We apply actions at the end of each iteration
        // We **cannot** apply actions at the end of rule,
        // because intermediate iterations may change state
        for(Integer i = 0; i < valueof(SupSize); i = i+1) begin
            if(!stop && fetchStage.pipelines[i].canDeq) begin
                let x = fetchStage.pipelines[i].first; // don't deq now, inst may not have resource
                let pc = x.pc;
                let ppc = x.ppc;
                let main_epoch = x.main_epoch;
                let dpTrain = x.dpTrain;
                let inst = x.inst;
                let dInst = x.dInst;
                let arch_regs = x.regs;
                let cause = x.cause;

                // check for wrong path, if wrong path, don't process it, leave to the other rule in next cycle
                if(!epochManager.checkEpoch[i].check(main_epoch)) begin
                    stop = True;
                end
                // for correct path
                // check ROB can be enq, otherwise cannot process
                if(!rob.enqPort[i].canEnq) begin
                    stop = True;
                end
                // check trap, if trap, cannot process, leave to the other rule in next cycle
                if(isValid(getTrap(x))) begin
                    stop = True;
                end
                // for system inst, must be the first one, otherwise cannot process now
                // leave to the next cycle
                Bool needReplay = doReplay(dInst.iType);
                if(needReplay && i != 0) begin
                    stop = True;
                end
                // check renaming table can be enq, otherwise cannot process now
                if(!regRenamingTable.rename[i].canRename) begin
                    stop = True;
                end
                // Figure out if there is new speculation and if there is
                // speculative renaming happening.
                Bool new_speculation = False;
                Bool speculative_renaming = False;
                if (needReplay) begin
                    // since we are incrementing the epoch in epochManager
                    // without redirecting, we will not need to get a
                    // spec tag because no speculation will be done.
                    new_speculation = False;
                end else if (dInst.execFunc matches tagged Mem .mem) begin
                    // This instruction can cause a page fault or misaligned
                    // address fault, so lets claim a checkpoint for this
                    // instruction that doesn't include any register renaming
                    // this instruction may have performed.
                    new_speculation = True;
                    speculative_renaming = True;
                end else if (dInst.execFunc matches tagged Br .br) begin
                    // This instruction can cause a redirection due to branch
                    // misprediction. Lets claim a checkpoint for this instruction.
                    // If this instruction is a JAL or JRAL instruction, then the
                    // checkpoint should include the renaming for the destination
                    // register.
                    new_speculation = True;
                    speculative_renaming = False;
                end
                // if need spec tag, check spec tag is available, otherwise cannot process
                if(new_speculation && (specTagClaimed || !specTagManager.canClaim)) begin
                    stop = True;
                end

                if(!stop) begin
                    // we can continue to analyze this inst
                    // Claim a speculation tag from the specTagManager if necessary
                    Maybe#(SpecTag) spec_tag = tagged Invalid;
                    if (new_speculation) begin
                        spec_tag = tagged Valid specTagManager.nextSpecTag;
                    end

                    // get renaming
                    // If the renaming is speculative, then the renaming will
                    // depend on the current spec_tag too.
                    let renaming_spec_bits = spec_bits | (speculative_renaming ? (1 << fromMaybe(?,spec_tag)) : 0);
                    let rename_result = regRenamingTable.rename[i].getRename(arch_regs);
                    let phy_regs = rename_result.phy_regs;

                    // scoreboard lookup
                    let regs_ready_cons = sbCons.eagerLookup[i].get(phy_regs);
                    let regs_ready_aggr = sbAggr.eagerLookup[i].get(phy_regs);

                    // get ROB tag
                    let inst_tag = rob.enqPort[i].getEnqInstTag;

                    // check execution pipelines availability
                    // this determines whether this inst can finally be processed
                    // so we will directly take actions on exe pipelines
                    Bool to_exec = False;
                    Bool to_mem = False;
                    Bool to_FpuMulDiv = False;
                    case (dInst.execFunc) matches
                        tagged Alu .alu:        to_exec = True;
                        tagged Br .br:          to_exec = True;
                        tagged MulDiv .muldiv:  to_FpuMulDiv = True;
                        tagged Fpu .fpu:        to_FpuMulDiv = True;
                        tagged Mem .mem:        to_mem = True;
                        default:
                            // Don't enqueue!
                            noAction;
                    endcase

                    if (to_exec) begin
                        // find an ALU pipeline
                        function Bool aluValid(Integer k) = !aluExeUsed[k] && reservationStationAlu[k].canEnq;
                        Vector#(AluExeNum, Integer) idxVec = genVector;
                        if(findIndex(aluValid, idxVec) matches tagged Valid .k) begin
                            // can process, send to ALU rs
                            aluExeUsed[k] = True; // mark resource used
                            reservationStationAlu[k].enq(ToReservationStation {
                                data: AluRSData {dInst: dInst, dpTrain: dpTrain},
                                regs: phy_regs,
                                tag: inst_tag,
                                spec_bits: spec_bits,
                                spec_tag: spec_tag,
                                regs_ready: regs_ready_aggr // alu will recv bypass
                            });
                        end
                        else begin
                            // cannot process this inst, stop
                            stop = True;
                        end
                    end
                    else if (to_FpuMulDiv) begin
                        if(!fpuMulDivExeUsed && reservationStationFpuMulDiv.canEnq) begin
                            // can process, send to FPU MUL DIV rs
                            fpuMulDivExeUsed = True; // mark resource used
                            reservationStationFpuMulDiv.enq(ToReservationStation {
                                data: FpuMulDivRSData {execFunc: dInst.execFunc},
                                regs: phy_regs,
                                tag: inst_tag,
                                spec_bits: spec_bits,
                                spec_tag: spec_tag,
                                regs_ready: regs_ready_aggr // fpu mul div recv bypass
                            });
                            doAssert(ppc == pc + 4, "FpuMulDiv next PC is not PC+4");
                            doAssert(!isValid(dInst.csr), "FpuMulDiv never explicitly read/write CSR");
                        end
                        else begin
                            // cannot process this inst, stop
                            stop = True;
                        end
                    end
                    else if (to_mem) begin
                        if (dInst.execFunc matches tagged Mem .mem_inst) begin
                            if(!memExeUsed && reservationStationMem.canEnq && lsq.canEnq) begin
                                // can process, send to Mem rs and LSQ
                                memExeUsed = True; // mark resource used
                                reservationStationMem.enq(ToReservationStation {
                                    data: MemRSData {
                                        mem_func: mem_inst.mem_func,
                                        imm: validValue(dInst.imm),
                                        ldstq_tag: lsq.enqTag
                                    },
                                    regs: phy_regs,
                                    tag: inst_tag,
                                    spec_bits: spec_bits,
                                    spec_tag: spec_tag,
                                    regs_ready: regs_ready_aggr // mem currently recv bypass
                                });
                                doAssert(ppc == pc + 4, "Mem next PC is not PC+4");
                                doAssert(!isValid(dInst.csr), "Mem never explicitly read/write CSR");
                                doAssert(isValid(dInst.imm), "Mem needs imm for virtual addr");
                                doAssert(isValid(spec_tag), "Mem needs spec tag for addr translate exception");
                                // put in ldstq
                                // XXX mark this row with specBits that contains this instructions specTag
                                let ldstq_spec_bits = spec_bits;
                                if (spec_tag matches tagged Valid .valid_spec_tag) begin
                                    ldstq_spec_bits = ldstq_spec_bits | (1 << valid_spec_tag);
                                end
                                lsq.enq(inst_tag, pc, mem_inst, phy_regs.dst, ldstq_spec_bits);
                            end
                            else begin
                                // cannot process this inst, stop
                                stop = True;
                            end
                        end
                        else begin
                            stop = True;
                            doAssert(False, "non memory instruction has to_mem == True");
                        end
                    end

                    // apply remaining actions if inst can be processed
                    if(!stop) begin
                        if(verbose) $display("[doRenaming - %d] ", i, fshow(x));

                        // deq fetch & update epochs match
                        fetchStage.pipelines[i].deq;
                        epochManager.updatePrevEpoch[i].update(main_epoch);
                        
                        // wait ROB empty and incrment epoch for system inst
                        // since this is the first inst, no need to ensure epoch can be incr
                        if (needReplay) begin
                            when(rob.isEmpty, noAction);
                            incrEpochWithoutRedirect;
                            stop = True; // stop after this system inst
                        end
                        
                        // Claim a speculation tag
                        if (new_speculation) begin
                            specTagClaimed = True; // mark resource used
                            specTagManager.claimSpecTag;
                        end

                        // Do renaming
                        regRenamingTable.rename[i].claimRename(arch_regs, renaming_spec_bits);

                        // Scoreboard Operations
                        sbCons.setBusy[i].set(phy_regs.dst);
                        sbAggr.setBusy[i].set(phy_regs.dst);

                        // display information
                        if (verbose) begin
                            $display("  [doRenaming - %d] regs_ready: cons ", i, fshow(regs_ready_cons), " ; aggr ", fshow(regs_ready_aggr));
                            if (arch_regs.src1 matches tagged Valid .valid_src) begin
                                if (phy_regs.src1 matches tagged Valid .valid_src_renamed) begin
                                    $fdisplay(stdout, "    [SRC RENAMING] ", fshow(valid_src), " -> ", fshow(valid_src_renamed));
                                end else begin
                                    $fdisplay(stdout, "    [SRC RENAMING] ERROR: ", fshow(valid_src), " -> INVALID");
                                end
                            end
                            if (arch_regs.src2 matches tagged Valid .valid_src) begin
                                if (phy_regs.src2 matches tagged Valid .valid_src_renamed) begin
                                    $fdisplay(stdout, "    [SRC RENAMING] ", fshow(valid_src), " -> ", fshow(valid_src_renamed));
                                end else begin
                                    $fdisplay(stdout, "    [SRC RENAMING] ERROR: ", fshow(valid_src), " -> INVALID");
                                end
                            end
                            if (arch_regs.src3 matches tagged Valid .valid_src) begin
                                if (phy_regs.src3 matches tagged Valid .valid_src_renamed) begin
                                    $fdisplay(stdout, "    [SRC RENAMING] ", fshow(valid_src), " -> ", fshow(valid_src_renamed));
                                end else begin
                                    $fdisplay(stdout, "    [SRC RENAMING] ERROR: ", fshow(valid_src), " -> INVALID");
                                end
                            end
                            if (arch_regs.dst matches tagged Valid .valid_dst) begin
                                if (phy_regs.dst matches tagged Valid .valid_dst_renamed) begin
                                    $fdisplay(stdout, "    [DST RENAMING] ", fshow(valid_dst), " => ", fshow(valid_dst_renamed));
                                end else begin
                                    $fdisplay(stdout, "    [DST RENAMING] ERROR: ", fshow(valid_dst), " -> INVALID");
                                end
                            end
                        end

                        // Enqueue into reorder buffer
                        Bool will_dirty_fpu_state = False;
                        if (arch_regs.dst matches tagged Valid( tagged Fpu .r )) begin
                            will_dirty_fpu_state = True;
                        end
                        RobInstState rob_inst_state = (to_exec || to_mem || to_FpuMulDiv) ? InRStation : Executed;

                        let y = ToReorderBuffer{pc: pc,
                                                iType: dInst.iType,
                                                csr: dInst.csr,
                                                claimed_phy_reg: True, // XXX we always claim a free reg in rename
                                                trap: Invalid, // no trap
                                                // default values of FullResult
                                                ppc_vaddr_csrData: PPC (ppc), // default use PPC
                                                fflags: 0,
                                                ////////
                                                will_dirty_fpu_state: will_dirty_fpu_state,
                                                rob_inst_state: rob_inst_state,
                                                spec_bits: spec_bits,
                                                spec_tag: spec_tag
`ifdef VERIFICATION_PACKETS
                                                , inst: inst
                                                , arch_reg_dst: arch_regs.dst
                                                , result_data: 0 // default val of FullResult
`endif
                                               };
                        rob.enqPort[i].enq(y);

                        // record activity
                        doCorrectPath = True;
                        renameCnt = renameCnt + 1;

                        // update spec bits if spec tag is claimed
                        if(spec_tag matches tagged Valid .t) begin
                            spec_bits = spec_bits | (1 << t);
                        end
                    end
                end
            end
        end

        // only fire this rule if we make some progress
        // otherwise this rule may block other rules forever
        when(doCorrectPath, noAction);

`ifdef PERF_COUNT
        if(inIfc.doStats) begin
            if(renameCnt > 1) begin
                supRenameCnt.incr(1);
            end
        end
`endif

`ifdef CHECK_DEADLOCK
        if(doCorrectPath) begin
            renameCorrectPath.send;
        end
`endif
    endrule


`ifdef CHECK_DEADLOCK
    interface renameInstStuck = toGet(renameInstStuckQ);
    interface renameCorrectPathStuck = toGet(renameCorrectPathStuckQ);
`else
    interface renameInstStuck = nullGet;
    interface renameCorrectPathStuck = nullGet;
`endif

    method Data getPerf(ExeStagePerfType t);
        return (case(t)
`ifdef PERF_COUNT
            SupRenameCnt: supRenameCnt;
`endif
            default: 0;
        endcase);
    endmethod
endmodule
