
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

import Types::*;
import ProcTypes::*;
import MemoryTypes::*;
import Vector::*;
import DefaultValue::*;

Bit#(3) memWU   = 3'b110;

// Smaller decode functions
function Maybe#(MemInst) decodeMemInst(Instruction inst);
    RiscVISASubset isa = defaultValue;
    MemInst mem_inst = MemInst{ mem_func: ?,
                                amo_func: None,
                                unsignedLd: False,
                                byteEn: replicate(False),
                                aq: False,
                                rl: False };
    Bool illegalInst = False;
    Opcode opcode = unpack(inst[6:0]);
    let funct5 = inst[31:27];
    let funct3 = inst[14:12];

    // mem_func + amo_func
    MemFunc mem_func = Ld;
    AmoFunc amo_func = None;
    if (opcode == Load || opcode == LoadFp) begin
        mem_func = Ld;
    end else if (opcode == Store || opcode == StoreFp) begin
        mem_func = St;
    end else if (opcode == Amo) begin
        case (funct5)
            fnLR       : mem_func = Lr;
            fnSC       : mem_func = Sc;
            fnAMOSWAP,
            fnAMOADD,
            fnAMOXOR,
            fnAMOAND,
            fnAMOOR,
            fnAMOMIN,
            fnAMOMAX,
            fnAMOMINU,
            fnAMOMAXU  : mem_func = Amo;
            default    : illegalInst = True;
        endcase
        // now for amo_func
        case (funct5)
            fnAMOSWAP : amo_func = Swap;
            fnAMOADD  : amo_func = Add;
            fnAMOXOR  : amo_func = Xor;
            fnAMOAND  : amo_func = And;
            fnAMOOR   : amo_func = Or;
            fnAMOMIN  : amo_func = Min;
            fnAMOMAX  : amo_func = Max;
            fnAMOMINU : amo_func = Minu;
            fnAMOMAXU : amo_func = Maxu;
        endcase
    end else begin
        illegalInst = True;
    end

    // unsignedLd
    // it doesn't matter if this is set to True for stores
    Bool unsignedLd = False;
    case (funct3)
        memB, memH, memW, memD:
            unsignedLd = False;
        memBU, memHU, memWU:
            unsignedLd = True;
        default:
            illegalInst = True;
    endcase
    // This is a minor fix to make our processor's results match spike since
    // they don't sign extend when loading single precision values from memory
    if (opcode == LoadFp) begin
        unsignedLd = True;
    end

    // byteEn
    // TODO: Some combinations of operations and byteEn's are illegal.
    // They should be detected here.
    ByteEn byteEn = replicate(False);
    case (funct3)
        memB, memBU : byteEn[0] = True;
        memH, memHU : begin
                          byteEn[0] = True;
                          byteEn[1] = True;
                      end
        memW, memWU : begin
                          byteEn[0] = True;
                          byteEn[1] = True;
                          byteEn[2] = True;
                          byteEn[3] = True;
                      end
        memD        : byteEn = replicate(True);
        default     : illegalInst = True;
    endcase

    // aq + rl
    Bool aq = False;
    Bool rl = False;
    if (opcode == Amo) begin
        // aq and rl are only defined for Amo operations
        aq = unpack(inst[ 26 ]);
        rl = unpack(inst[ 25 ]);
    end

    if (illegalInst) begin
        return tagged Invalid;
    end else begin
        return tagged Valid ( MemInst{
                                mem_func: mem_func,
                                amo_func: amo_func,
                                unsignedLd: unsignedLd,
                                byteEn: byteEn,
                                aq: aq,
                                rl: rl } );
    end
endfunction

(* noinline *)
function DecodeResult decode(Instruction inst);
  RiscVISASubset isa = defaultValue;

  // initialize dInst with default values
  DecodedInst dInst = DecodedInst{
    iType: Unsupported,
    execFunc: tagged Other,
    csr: tagged Invalid,
    imm: tagged Invalid};
  ArchRegs regs = ArchRegs{
    src1: tagged Invalid,
    src2: tagged Invalid,
    src3: tagged Invalid,
    dst: tagged Invalid};
  Bool illegalInst = False;

  Opcode opcode = unpack(inst[  6 :  0 ]);
  let rd        =        inst[ 11 :  7 ];
  let funct3    =        inst[ 14 : 12 ];
  let rs1       =        inst[ 19 : 15 ];
  let rs2       =        inst[ 24 : 20 ];
  let funct7    =        inst[ 31 : 25 ];
  // For "F" and "D" ISA extensions
  let funct5    =        inst[ 31 : 27 ];
  let fmt       =        inst[ 26 : 25 ];
  let rs3       =        inst[ 31 : 27 ];
  let funct2    =        inst[ 26 : 25 ];
  // For "A" ISA extension
  Bool aq       = unpack(inst[ 26 ]);
  Bool rl       = unpack(inst[ 25 ]);

  ImmData immI   = signExtend(inst[31:20]);
  ImmData immS   = signExtend({ inst[31:25], inst[11:7] });
  ImmData immB   = signExtend({ inst[31], inst[7], inst[30:25], inst[11:8], 1'b0});
  ImmData immU   = signExtend({ inst[31:12], 12'b0 });
  ImmData immJ   = signExtend({ inst[31], inst[19:12], inst[20], inst[30:21], 1'b0});

  // Results of mini-decoders
  Maybe#(MemInst) mem_inst = decodeMemInst(inst);

  case (opcode)
    OpImm:
    begin
      dInst.iType = Alu;
      dInst.execFunc = tagged Alu (case (funct3)
        fnADD: Add;
        fnSLT: Slt;
        fnSLTU: Sltu;
        fnAND: And;
        fnOR: Or;
        fnXOR: Xor;
        fnSLL: Sll;
        fnSR: (immI[10] == 0 ? Srl : Sra);
      endcase);
      regs.dst  = Valid(tagged Gpr rd);
      regs.src1 = Valid(tagged Gpr rs1);
      regs.src2 = Invalid;
      dInst.imm = Valid(immI);
      dInst.csr = tagged Invalid;
    end

    OpImm32:
    begin
      dInst.iType = Alu;
      dInst.execFunc = tagged Alu (case (funct3)
        fnADD: Addw;
        fnSLL: Sllw;
        fnSR: (immI[10] == 0 ? Srlw : Sraw);
      endcase);
      regs.dst  = Valid(tagged Gpr rd);
      regs.src1 = Valid(tagged Gpr rs1);
      regs.src2 = Invalid;
      dInst.imm = Valid(immI);
      dInst.csr = tagged Invalid;
    end

    Op:
    begin
      dInst.iType = Alu;
      regs.dst  = Valid(tagged Gpr rd);
      regs.src1 = Valid(tagged Gpr rs1);
      regs.src2 = Valid(tagged Gpr rs2);
      dInst.imm  = Invalid;
      dInst.csr = tagged Invalid;
      case (funct7)
        opALU1:
        begin
          dInst.execFunc = tagged Alu (case(funct3)
            fnADD: Add;
            fnSLT: Slt;
            fnSLTU: Sltu;
            fnAND: And;
            fnOR: Or;
            fnXOR: Xor;
            fnSLL: Sll;
            fnSR: Srl;
          endcase);
        end
        opALU2:
        begin
          dInst.execFunc = tagged Alu (case (funct3)
            fnADD: Sub;
            fnSR: Sra;
          endcase);
        end
        opMULDIV:
        begin
          if (isa.m) begin
            // Processor includes "M" extension
            MulDivFunc func = (case(funct3)
                fnMUL    : Mul;
                fnMULH   : Mulh;
                fnMULHSU : Mulh;
                fnMULHU  : Mulh;
                fnDIV    : Div;
                fnDIVU   : Div;
                fnREM    : Rem;
                fnREMU   : Rem;
              endcase);
            Bool w = False;
            MulDivSign sign = (case(funct3)
                fnMUL    : Signed;
                fnMULH   : Signed;
                fnMULHSU : SignedUnsigned;
                fnMULHU  : Unsigned;
                fnDIV    : Signed;
                fnDIVU   : Unsigned;
                fnREM    : Signed;
                fnREMU   : Unsigned;
              endcase);
            dInst.execFunc = tagged MulDiv (MulDivInst{func: func, w: w, sign: sign});
          end else begin
            // Processor doesn't include "M" extension
            illegalInst = True;
          end
        end
      endcase
    end

    Op32:
    begin
      dInst.iType = Alu;
      case (funct7)
        opALU1:
        begin
          dInst.execFunc = tagged Alu (case(funct3)
            fnADD: Addw;
            fnSLL: Sllw;
            fnSR: Srlw;
          endcase);
        end
        opALU2:
        begin
          dInst.execFunc = tagged Alu (case (funct3)
            fnADD: Subw;
            fnSR: Sraw;
          endcase);
        end
        opMULDIV:
        begin
          if (isa.m) begin
            // Processor includes "M" extension
            MulDivFunc func = (case(funct3)
                fnMUL    : Mul;
                fnMULH   : Mulh; // illegal
                fnMULHSU : Mulh; // illegal
                fnMULHU  : Mulh; // illegal
                fnDIV    : Div;
                fnDIVU   : Div;
                fnREM    : Rem;
                fnREMU   : Rem;
              endcase);
            Bool w = True;
            MulDivSign sign = (case(funct3)
                fnMUL    : Signed;
                fnMULH   : Signed; // illegal
                fnMULHSU : SignedUnsigned; // illegal
                fnMULHU  : Unsigned; // illegal
                fnDIV    : Signed;
                fnDIVU   : Unsigned;
                fnREM    : Signed;
                fnREMU   : Unsigned;
              endcase);
            dInst.execFunc = tagged MulDiv (MulDivInst{func: func, w: w, sign: sign});
          end else begin
            // Processor doesn't include "M" extension
            illegalInst = True;
          end
        end
      endcase
      regs.dst  = Valid(tagged Gpr rd);
      regs.src1 = Valid(tagged Gpr rs1);
      regs.src2 = Valid(tagged Gpr rs2);
      dInst.imm  = Invalid;
      dInst.csr = tagged Invalid;
    end

    Lui:
    begin
      dInst.iType = Alu;
      dInst.execFunc = tagged Alu Add;
      regs.dst = Valid(tagged Gpr rd);
      regs.src1 = Valid(tagged Gpr 0);
      regs.src2 = Invalid;
      dInst.imm = Valid(immU);
      dInst.csr = tagged Invalid;
    end

    Auipc:
    begin
      dInst.iType = Auipc;
      dInst.execFunc = tagged Alu Add;
      regs.dst   = Valid(tagged Gpr rd);
      regs.src1  = Invalid;
      regs.src2  = Invalid;
      dInst.imm   = Valid(immU);
      dInst.csr = tagged Invalid;
    end

    Jal:
    begin
      dInst.iType = J;
      regs.dst  = Valid(tagged Gpr rd);
      regs.src1 = Invalid;
      regs.src2 = Invalid;
      dInst.imm  = Valid(immJ);
      dInst.csr = tagged Invalid;
      dInst.execFunc = tagged Br AT;
    end

    Jalr:
    begin
      dInst.iType = Jr;
      regs.dst  = Valid(tagged Gpr rd);
      regs.src1 = Valid(tagged Gpr rs1);
      regs.src2 = Invalid;
      dInst.imm  = Valid(immI);
      dInst.csr = tagged Invalid;
      dInst.execFunc = tagged Br AT;
    end

    Branch:
    begin
      dInst.iType = Br;
      dInst.execFunc = tagged Br (case(funct3)
        fnBEQ: Eq;
        fnBNE: Neq;
        fnBLT: Lt;
        fnBLTU: Ltu;
        fnBGE: Ge;
        fnBGEU: Geu;
      endcase);
      regs.dst  = Invalid;
      regs.src1 = Valid(tagged Gpr rs1);
      regs.src2 = Valid(tagged Gpr rs2);
      dInst.imm  = Valid(immB);
      dInst.csr = tagged Invalid;
    end

    Load:
    begin
      dInst.iType = Ld;
      if (isValid(mem_inst)) begin
        dInst.execFunc = tagged Mem fromMaybe(?, mem_inst);
      end else begin
        illegalInst = True;
      end
      regs.dst  = Valid(tagged Gpr rd);
      regs.src1 = Valid(tagged Gpr rs1);
      regs.src2 = Invalid;
      dInst.imm    = Valid(immI);
      dInst.csr = tagged Invalid;
    end

    Store:
    begin
      dInst.iType = St;
      if (isValid(mem_inst)) begin
        dInst.execFunc = tagged Mem fromMaybe(?, mem_inst);
      end else begin
        illegalInst = True;
      end
      regs.dst  = Invalid;
      regs.src1 = Valid(tagged Gpr rs1);
      regs.src2 = Valid(tagged Gpr rs2);
      dInst.imm    = Valid(immS);
      dInst.csr = tagged Invalid;
    end

    Amo:
    begin
      if (!isa.a) begin
        // unsupported
        illegalInst = True;
      end else begin
        // AMO defaults
        dInst.iType = Amo;
        regs.dst  = Valid(tagged Gpr rd);
        regs.src1 = Valid(tagged Gpr rs1);
        regs.src2 = Valid(tagged Gpr rs2);
        dInst.imm  = Valid(0);
        dInst.csr = Invalid;

        case (funct5)
          fnLR:
          begin
            dInst.iType = Lr;
            if (isValid(mem_inst)) begin
              dInst.execFunc = tagged Mem fromMaybe(?, mem_inst);
            end else begin
              illegalInst = True;
            end
            regs.dst  = Valid(tagged Gpr rd);
            regs.src1 = Valid(tagged Gpr rs1);
            regs.src2 = Invalid;
            dInst.imm  = Valid(0);
            dInst.csr  = Invalid;
          end

          fnSC:
          begin
            dInst.iType = Sc;
            if (isValid(mem_inst)) begin
              dInst.execFunc = tagged Mem fromMaybe(?, mem_inst);
            end else begin
              illegalInst = True;
            end
            regs.dst  = Valid(tagged Gpr rd);
            regs.src1 = Valid(tagged Gpr rs1);
            regs.src2 = Valid(tagged Gpr rs2);
            dInst.imm  = Valid(0);
            dInst.csr  = Invalid;
          end

          fnAMOSWAP,
          fnAMOADD,
          fnAMOXOR,
          fnAMOAND,
          fnAMOOR,
          fnAMOMIN,
          fnAMOMAX,
          fnAMOMINU,
          fnAMOMAXU:
          begin
            if (isValid(mem_inst)) begin
              dInst.execFunc = tagged Mem fromMaybe(?, mem_inst);
            end else begin
              illegalInst = True;
            end
          end

          default:
          begin
            illegalInst = True;
          end
        endcase
      end
    end

    // Instructions for "F" and "D" ISA extensions - FPU
    OpFp:
      begin
        // check if instruction is supported
        if ((fmt == fmtS && !isa.f) || (fmt == fmtD && !isa.d) || (fmt != fmtS && fmt != fmtD))
        begin
          illegalInst = True;
        end else begin
          // Instruction is supported
          dInst.iType = Fpu;
          regs.dst  = Valid(tagged Fpu rd);
          regs.src1 = Valid(tagged Fpu rs1);
          regs.src2 = Valid(tagged Fpu rs2);
          dInst.imm  = Invalid;
          dInst.csr = tagged Invalid;
          FpuFunc func = (case (funct5)
            opFADD:     FAdd;
            opFSUB:     FSub;
            opFMUL:     FMul;
            opFDIV:     FDiv;
            opFSQRT:    FSqrt;
            opFSGNJ:    ((funct3 == 0) ? FSgnj : ((funct3 == 1) ? FSgnjn : FSgnjx));
            opFMINMAX:  ((funct3 == 0) ? FMin : FMax);
            opFCMP:     ((funct3 == 0) ? FLe : ((funct3 == 1) ? FLt : FEq));
            opFMV_XF:   ((funct3 == 0) ? FMv_XF : FClass); // also CLASS
            opFMV_FX:   FMv_FX;
            opFCVT_FF:  FCvt_FF;
            opFCVT_WF:  ((rs2 == 0) ? FCvt_WF : ((rs2 == 1) ? FCvt_WUF : ((rs2 == 2) ? FCvt_LF : FCvt_LUF)));
            opFCVT_FW:  ((rs2 == 0) ? FCvt_FW : ((rs2 == 1) ? FCvt_FWU : ((rs2 == 2) ? FCvt_FL : FCvt_FLU)));
          endcase);
          FpuPrecision precision = (fmt == fmtS) ? Single : Double;
          dInst.execFunc = tagged Fpu(FpuInst{func: func, rm: unpack(funct3), precision: precision});
          // Special cases
          case (funct5)
            opFSQRT:
            begin
              regs.dst  = Valid(tagged Fpu rd);
              regs.src1 = Valid(tagged Fpu rs1);
              regs.src2 = Invalid;
            end
            opFCMP:
            begin
              regs.dst  = Valid(tagged Gpr rd);
              regs.src1 = Valid(tagged Fpu rs1);
              regs.src2 = Valid(tagged Fpu rs2);
            end
            opFMV_XF:
            begin
              regs.dst  = Valid(tagged Gpr rd);
              regs.src1 = Valid(tagged Fpu rs1);
              regs.src2 = Invalid;
            end
            opFMV_FX:
            begin
              regs.dst  = Valid(tagged Fpu rd);
              regs.src1 = Valid(tagged Gpr rs1);
              regs.src2 = Invalid;
            end
            opFCVT_FF:
            begin
              regs.dst  = Valid(tagged Fpu rd);
              regs.src1 = Valid(tagged Fpu rs1);
              regs.src2 = Invalid;
            end
            opFCVT_WF:
            begin
              regs.dst  = Valid(tagged Gpr rd);
              regs.src1 = Valid(tagged Fpu rs1);
              regs.src2 = Invalid;
            end
            opFCVT_FW:
            begin
              regs.dst  = Valid(tagged Fpu rd);
              regs.src1 = Valid(tagged Gpr rs1);
              regs.src2 = Invalid;
            end
          endcase
        end
      end
    LoadFp:
      begin
        // check if instruction is supported
        if (!isa.f && !isa.d)
        begin
          // FIXME: Check more cases
          illegalInst = True;
        end else begin
          // Same decode logic as Int Ld
          dInst.iType = Ld;
          if (isValid(mem_inst)) begin
            dInst.execFunc = tagged Mem fromMaybe(?, mem_inst);
          end else begin
            illegalInst = True;
          end
          regs.dst  = Valid(tagged Fpu rd);
          regs.src1 = Valid(tagged Gpr rs1);
          regs.src2 = Invalid;
          dInst.imm    = Valid(immI);
          dInst.csr = tagged Invalid;
        end
      end
    StoreFp:
      begin
        // check if instruction is supported
        if (!isa.f && !isa.d)
        begin
          // FIXME: Check more cases
          illegalInst = True;
        end else begin
          // Same decode logic as Int St
          dInst.iType = St;
          if (isValid(mem_inst)) begin
            dInst.execFunc = tagged Mem fromMaybe(?, mem_inst);
          end else begin
            illegalInst = True;
          end
          regs.dst  = Invalid;
          regs.src1 = Valid(tagged Gpr rs1);
          regs.src2 = Valid(tagged Fpu rs2);
          dInst.imm    = Valid(immS);
          dInst.csr = tagged Invalid;
        end
      end
    Fmadd, Fmsub, Fnmsub, Fnmadd:
      begin
        // FMA is overrated
        illegalInst = True;
        /*
        // check if instruction is supported
        if ((fmt == fmtS && !isa.f) || (fmt == fmtD && !isa.d) || (fmt != fmtS && fmt != fmtD))
        begin
          dInst.iType = Unsupported;
          illegalInst = True;
        end else begin
          // Instruction is supported
          dInst.iType = (fmt == fmtS) ? FpS : FpD;
          dInst.execFunc = tagged Fpu (case (opcode)
              Fmadd:  FMAdd;
              Fmsub:  FMSub;
              Fnmsub: FNMSub;
              Fnmadd: FNMAdd;
              default: ?;
            endcase);
          regs.src1 = Valid(tagged Fpu rs1);
          regs.src2 = Valid(tagged Fpu rs2);
          regs.src3 = Valid(rs3);
          regs.dst = Valid(tagged Fpu rd);
          dInst.csr = Invalid;
          dInst.imm = Invalid;
        end
        */
      end

    MiscMem:
    begin
      dInst.iType = Fence;
      dInst.execFunc = tagged Other;
      regs.dst  = Valid(tagged Gpr 0);
      regs.src1 = Valid(tagged Gpr 0);
      regs.src2 = Invalid;
      dInst.imm  = Valid(0);
      dInst.csr  = Invalid;
    end

    System:
    begin
      if (funct3 == fnPRIV)
      begin
        dInst.iType = (case (truncate(immI))
            privSFENCEVM: SFence;
            privSRET: Sret;
            privMRTS: Mrts;
            default: Priv;
          endcase);
        regs.dst  = Invalid;
        regs.src1 = Valid(tagged Gpr rs1);
        regs.src2 = Invalid;
        dInst.imm  = (truncate(immI) == privSFENCEVM ? Valid(0) : Valid(immI));
        dInst.csr = tagged Invalid;
      end else // fnCSRRWI, fnCSRRW, fnCSRRSI, fnCSRRS, fnCSRRCI, fnCSRRC
      begin
        dInst.iType = Csr;
        dInst.execFunc = (case (funct3)
            fnCSRRWI, fnCSRRW: tagged Alu Csrw;
            fnCSRRSI, fnCSRRS: tagged Alu Csrs;
            fnCSRRCI, fnCSRRC: tagged Alu Csrc;
          endcase);

        regs.dst = Valid(tagged Gpr rd);
        regs.src1 = Valid(tagged Gpr 0); // going to be CSR
        //                                           Reg     :          Imm
        regs.src2 = (funct3[2] == 0 ? Valid(tagged Gpr rs1) :                Invalid);
        dInst.imm  = (funct3[2] == 0 ?               Invalid : Valid(zeroExtend(rs1)));
        dInst.csr = Valid(unpack(truncate(immI)));
      end
    end

    default:
    begin
      illegalInst = True;
    end
  endcase

  if(regs.dst matches tagged Valid .dst &&& dst == tagged Gpr 0)
    regs.dst = tagged Invalid;

  return DecodeResult{dInst: dInst, regs: regs, illegalInst: illegalInst};
endfunction

// All this does is add the CSR state to the decoding
function DecodedInst updateRoundingMode(DecodedInst dInst, CsrState csrState);
    if (dInst.execFunc matches tagged Fpu .fpu_f) begin
        // update rounding mode
        let new_fpu_f = fpu_f;
        new_fpu_f.rm = (fpu_f.rm == RDyn) ? unpack(csrState.frm) : fpu_f.rm;
        dInst.execFunc = tagged Fpu new_fpu_f;
    end
    return dInst;
endfunction
