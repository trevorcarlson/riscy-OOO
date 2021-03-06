
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

import DefaultValue::*;
import Types::*;
import ProcTypes::*;
import HasSpecBits::*;
import ReservationStationEhr::*;

// ALU exe num = superscalar size
typedef SupSize AluExeNum;

// Phy RFile
// write: LrScAmo < Alu < FpuMulDiv < Ld
// read: Alu, FpuMulDiv, Mem
typedef TAdd#(3, AluExeNum) RFileWrPortNum;
typedef TAdd#(2, AluExeNum) RFileRdPortNum;

// sb lazy lookup num: same as RFile read, becaues all pipelines recv bypass
typedef RFileRdPortNum SbLazyLookupPortNum;

// ports for writing conservative elements
// i.e. write rf & set conservative sb & wake up rs in conservative pipeline (i.e. not recv bypass)
// ordering: LrScAmo < Alu < FpuMulDiv < Ld
typedef RFileWrPortNum WrConsPortNum;
Integer lrScAmoWrConsPort = 0;
function Integer aluWrConsPort(Integer i) = 1 + i;
Integer fpuMulDivWrConsPort = 1 + valueof(AluExeNum);
Integer ldWrConsPort = 2 + valueof(AluExeNum);

// ports for writing aggressive elements
// i.e. set aggressive sb & wake up rs in aggressive pipeline (i.e. recv bypass)
// ALU sets them in dispatch rule, and mem (Ld/Lr/Sc/Amo) sets them when cache hit or forwarding
// Since dispatch fire very last, ALU is ordered at last
// Since we do forward in doIssueLd while cache hit may also call LSQ.wakupLdBySt,
// forward is ordered before cache hit
// Ordering: FpuMulDiv < Forward < Cache hit < Alu
typedef TAdd#(3, AluExeNum) WrAggrPortNum;
Integer fpuMulDivWrAggrPort = 0;
Integer forwardWrAggrPort = 1;
Integer cacheWrAggrPort = 2;
function Integer aluWrAggrPort(Integer i) = 3 + i;

// ports for read rf & lazy lookup in sb, ordering doesn't matter
function Integer aluRdPort(Integer i) = i;
Integer fpuMulDivRdPort = valueof(AluExeNum);
Integer memRdPort = 1 + valueof(AluExeNum);

// ports for correct spec, ordering doesn't matter
typedef TAdd#(2, AluExeNum) CorrectSpecPortNum;
function Integer finishAluCorrectSpecPort(Integer i) = i;
Integer finishMemCorrectSpecPort = valueof(AluExeNum);
Integer deqLSQCorrectSpecPort = 1 + valueof(AluExeNum);

// ports for manual conflict with wrong spec, ordering doesn't matter
typedef 1 ConflictWrongSpecPortNum;
Integer finishFpuMulDivConflictWrongSpecPort = 0;

