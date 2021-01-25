// SL 2020-12-02 @sylefeb
// ------------------------- 
// The Fire-V core - RV32I CPU
// ------------------------- 
// 
// Note: rdinstret and rdcycle are limited to 32 bits
//       rdtime reports user_data instead of time
//
// --------------------------------------------------
//
//      GNU AFFERO GENERAL PUBLIC LICENSE
//        Version 3, 19 November 2007
//      
//  A copy of the license full text is included in 
//  the distribution, please refer to it for details.

// bitfields for easier decoding of instructions ; these
// define views on a uint32, that are used upon 
// access, avoiding hard coded values in part-selects
bitfield Itype {
  uint12 imm,
  uint5  rs1,
  uint3  funct3,
  uint5  rd,
  uint7  opcode
}

bitfield Stype {
  uint7  imm11_5,
  uint5  rs2,
  uint5  rs1,
  uint3  funct3,
  uint5  imm4_0,
  uint7  opcode
}

bitfield Rtype {
  uint1  unused_2,
  uint1  select2,
  uint5  unused_1,
  uint5  rs2,
  uint5  rs1,
  uint3  funct3,
  uint5  rd,
  uint7  opcode
}

bitfield Utype {
  uint20  imm31_12,
  uint12  zero
}

bitfield Jtype {
  uint1  imm20,
  uint10 imm10_1,
  uint1  imm11,
  uint8  imm_19_12,
  uint5  rd,
  uint7  opcode
}

bitfield Btype {
  uint1  imm12,
  uint6  imm10_5,
  uint5  rs2,
  uint5  rs1,
  uint3  funct3,
  uint4  imm4_1,
  uint1  imm11,
  uint7  opcode
}

// --------------------------------------------------

// memory 32 bits masked interface
group rv32i_ram_io
{
  uint32  addr       = 0, // 32 bits address space
  uint1   rw         = 0, // rw==1 on write, 0 on read
  uint4   wmask      = 0, // write mask
  uint32  data_in    = 0,
  uint32  data_out   = 0,
  uint1   in_valid   = 0,
  uint1   done       = 0 // pulses when a read or write is done
}

// interface for user
interface rv32i_ram_user {
  output  addr,
  output  rw,
  output  wmask,
  output  data_in,
  output  in_valid,
  input   data_out,
  input   done,
}

// interface for provider
interface rv32i_ram_provider {
  input   addr,
  input   rw,
  input   wmask,
  input   data_in,
  output  data_out,
  input   in_valid,
  output  done
}

// --------------------------------------------------
// The Risc-V RV32I CPU

algorithm rv32i_cpu(
  input uint26   boot_at,
  input uint32   user_data,
  rv32i_ram_user ram,
  output uint26  predicted_addr, // next predicted address
  output uint1   predicted_correct,
) <autorun> {
  
  // does not have to be simple_dualport_bram, but results in smaller design
  simple_dualport_bram int32 xregsA[32] = {0,pad(uninitialized)};
  simple_dualport_bram int32 xregsB[32] = {0,pad(uninitialized)};
  
  uint1  cmp         = uninitialized;
  uint1  instr_ready(0);
  // uint1  halt(0);
  
  uint5  write_rd    = uninitialized;
  uint1  jump        = uninitialized;  
  uint1  branch      = uninitialized;
   
  uint3  csr         = uninitialized;
  
  uint3  select      = uninitialized;  
  uint1  sub         = uninitialized;
  uint1  signedShift = uninitialized; 
  
  uint32 instr(0);
  uint26 pc(0);
  uint32 next_instr(0);
  uint26 next_pc(0);

  uint26 next_pc_p4 ::= next_pc + 4;
  uint26 next_pc_p8 ::= next_pc + 8;

  uint1 pcOrReg     = uninitialized;
  uint1 regOrImm    = uninitialized;
  
  uint1 load_store  = uninitialized;
  uint1 store       = uninitialized;
  uint3 loadStoreOp = uninitialized;
  uint1 rd_enable   = uninitialized;
  
  uint1 saved_store       = uninitialized;
  uint3 saved_loadStoreOp = uninitialized;
  uint1 saved_rd_enable   = uninitialized;
  
  uint32 refetch_addr = uninitialized;
  uint1  refetch_rw(0);
  
  int32 aluA        = uninitialized;
  int32 aluB        = uninitialized;
  int32 imm         = uninitialized;
  int32 regA        = uninitialized;
  int32 regB        = uninitialized;
  
  decode dec(
    instr       <: instr,
    pc          <: pc,
    regA        <: regA,
    regB        <: regB,
    write_rd    :> write_rd,
    jump        :> jump,
    branch      :> branch,
    load_store  :> load_store,
    store       :> store,
    loadStoreOp :> loadStoreOp,
    select      :> select,
    sub         :> sub,
    signedShift :> signedShift,
    pcOrReg     :> pcOrReg,
    regOrImm    :> regOrImm,
    csr         :> csr,
    rd_enable   :> rd_enable,
    aluA        :> aluA,
    aluB        :> aluB,
    imm         :> imm,
  );
 
  uint3 funct3   ::= Btype(instr).funct3; 
  uint1  branch_or_jump = uninitialized;

  int32  alu_out     = uninitialized;
  int32  wreg        = uninitialized;
  intops alu(
    pc          <:: pc,
    xa          <: aluA,
    xb          <: aluB,
    imm         <: imm,
    pcOrReg     <: pcOrReg,
    regOrImm    <: regOrImm,
    select      <: select,
    sub         <: sub,
    signedShift <: signedShift,
    csr         <: csr,
    cycle      <:: cycle,
    instret    <:: instret,
    user_data  <:: user_data,
    r           :> alu_out,
    ra         <:: regA,
    rb         <:: regB,
    funct3     <:  funct3,
    branch     <:  branch,
    jump       <:  jump,
    j          :>  branch_or_jump,
    w          :>  wreg,
  );

  uint32 cycle(0);
  uint32 instret(0);

$$if SIMULATION then
  uint32 cycle_last_retired(0);
$$end

  uint1  refetch         = 1;
  uint1  wait_next_instr = 0;
  uint1  commit_decode   = 0;
  uint1  do_load_store   = 0;
  uint1  start           = 1;

  uint4  case_select   = uninitialized;

  // maintain ram in_valid low (pulses high when needed)
  ram.in_valid    := 0; 
  
  always {
  
    case_select = {
                    refetch                         & (ram.done | start),
                   ~refetch         & do_load_store & ram.done, // performing load store, data available
                    wait_next_instr                 & ram.done,    // instruction avalable
                    commit_decode
                  };
                  
  //} 

//  __display("cycle %d case_select %d refetch %b wait_next_instr %b commit_decode %b",cycle,case_select,refetch,wait_next_instr,commit_decode);

$$if HARDWARE then  
  //while (1) {
$$else    
  //while (!halt) {
$$end    
  // while (cycle < 400) {
  // while (instret < 128) {
$$if verbose then
    if (ram.done) {
      __display("**** ram done (cycle %d) **** ram.data_out @%h = %h",cycle,ram.addr,ram.data_out);        
    }
$$end
    switch (case_select) {

      case 8: {
$$if verbose then
      if (~reset) {
        __display("----------- CASE 8: refetch ------------- (cycle %d)",cycle);
      }
      //__display("  [refetch] (cycle %d) @%h load_store %b",cycle,ram.addr,do_load_store);        
      //__display("  [instr ready:%b] pc @%h   next_pc @%h  next_pc+4 @%h",instr_ready,pc,next_pc,next_pc+4);
      //__display("  [refetch] NEXT PC @%h",next_pc);        
$$end
        refetch         = 0;

        // record next instruction
        next_instr      = ram.data_out;
        // prepare load registers for next instruction
        xregsA.addr0    = Rtype(next_instr).rs1;
        xregsB.addr0    = Rtype(next_instr).rs2;
$$if verbose then        
//__display("  [setup regs read] regA[%d] regB[%d]",xregsA.addr0,xregsB.addr0);        
$$end
        predicted_correct = instr_ready;
        predicted_addr    = next_pc_p4;

        // refetch
        ram.addr          = start ? boot_at : refetch_addr;
        // cold start?
        next_pc           = start ? boot_at : next_pc;
        if (start & ~reset) {
          __display("CPU RESET %d (@%h) start:%b",case_select,next_pc,start);
        }        
        start             = reset;

$$if verbose then
//__display("  [RAM ADDR] @%h",ram.addr);
$$end        
        ram.rw            = refetch_rw;
        ram.in_valid      = ~reset;
        instr_ready       = do_load_store;
        wait_next_instr   = ~do_load_store;

      }
    
      case 4: {
$$if verbose then
        __display("----------- CASE 4: load / store ------------- (cycle %d)",cycle);
        //__display("  [load store] (cycle %d) store %b",cycle,saved_store);
$$end        
        do_load_store   = 0;
        // data with memory access
        if (~saved_store) { 
          // finalize load
          uint32 tmp = uninitialized;
          switch ( saved_loadStoreOp[0,2] ) {
            case 2b00: { // LB / LBU
              tmp = { {24{(~saved_loadStoreOp[2,1])&ram.data_out[ 7,1]}},ram.data_out[ 0,8]};
            }
            case 2b01: { // LH / LHU
              tmp = { {16{(~saved_loadStoreOp[2,1])&ram.data_out[15,1]}},ram.data_out[ 0,16]};
            }
            case 2b10: { // LW
              tmp = ram.data_out;  
            }
            default: { tmp = 0; }
          }            
          // write result to register
          xregsA.wenable1 = saved_rd_enable;
          xregsB.wenable1 = saved_rd_enable;
          xregsA.wdata1   = tmp;
          xregsB.wdata1   = tmp;
$$if verbose then
if (xregsA.wenable1) {
//__display("  [regs WRITE] regA[%d]=%h regB[%d]=%h",xregsA.addr1,xregsA.wdata1,xregsB.addr1,xregsB.wdata1);
}
$$end
        }
        
        // be optimistic: request next-next instruction
        ram.addr       = next_pc_p4;
$$if verbose then
//__display("  [RAM ADDR] @%h",ram.addr);
$$end
        // register conflict?
        if ((Rtype(next_instr).rs1 == xregsA.addr1
          || Rtype(next_instr).rs2 == xregsB.addr1
          || Rtype(instr     ).rs1 == xregsA.addr1
          || Rtype(instr     ).rs2 == xregsB.addr1) & saved_rd_enable) {
          // too bad, but we have to write a register that was already
          // read for the prefetched instructions ... play again!
          refetch         = 1;
          refetch_addr    = pc;
          next_pc         = pc;
          instr_ready     = 0;
          // predicted_addr  = pc;
$$if verbose then
          //__display("  [load store] NEXT PC @%h",next_pc);        
          __display("****** register conflict *******");
$$end          
        } else {
          commit_decode     = 1;
        }
        ram.in_valid      = 1;
        ram.rw            = 0;
        predicted_addr    = next_pc_p8;
        predicted_correct = 1;
      } // case 4

      case 2: {
$$if verbose then      
      __display("----------- CASE 2 : ALU / fetch ------------- (cycle %d)",cycle);
      //__display("  (cycle %d) ram.data_out:%h",cycle,ram.data_out);
      //__display("  [instr ready:%b] pc @%h   next_pc @%h  next_pc+4 @%h",instr_ready,pc,next_pc,next_pc+4);
$$end      
        // Note: ALU for previous (if any) is running ...
        wait_next_instr   = 0;
        // record next instruction
        next_instr        = ram.data_out;
        // prepare load registers for next instruction
        xregsA.addr0      = Rtype(next_instr).rs1;
        xregsB.addr0      = Rtype(next_instr).rs2;
$$if verbose then
//__display("  [setup regs read] regA[%d] regB[%d]",xregsA.addr0,xregsB.addr0);        
$$end
        commit_decode     = 1;
        predicted_correct = 1;

        // be optimistic: request next-next instruction
        ram.addr          = next_pc_p4;
$$if verbose then
//__display("  [RAM ADDR] @%h",ram.addr);
$$end
        ram.in_valid      = 1;
        ram.rw            = 0;
      }
      
      case 1: {
$$if verbose then     
        __display("----------- CASE 1 : commit / decode ------------- (cycle %d)",cycle);
        if (~instr_ready) {
          __display("========> [next instruction] load_store %b branch_or_jump %b",load_store,branch_or_jump);
        } else {
           __display("========> [ALU done <<%h>> (%d since)] pc %h alu_out %h load_store:%b store:%b branch_or_jump:%b rd_enable:%b write_rd:%d aluA:%d aluB:%d regA:%d regB:%d",instr,cycle-cycle_last_retired,pc,alu_out,load_store,store,branch_or_jump,rd_enable,write_rd,aluA,aluB,regA,regB);
          //__display("========> [ALU done <<%h>> (%d since) cycle %d instret %d] pc %h load_store:%b store:%b branch_or_jump:%b",instr,cycle-cycle_last_retired,cycle,instret,pc,load_store,store,branch_or_jump);
          cycle_last_retired = cycle;
        }
$$end        
        commit_decode = 0;
        // Note: nothing received from memory
$$if SIMULATION then
        // halt   = instr_ready & (instr == 0);
        // if (halt) { __display("HALT on zero-instruction"); }
$$end
        // commit previous instruction
        // load store next?
        do_load_store     = instr_ready & load_store;
        saved_store       = store;
        saved_loadStoreOp = loadStoreOp;
        saved_rd_enable   = rd_enable;
        // need to refetch from RAM next?
        refetch           = instr_ready & (branch_or_jump | load_store); // ask to fetch from the new address (cannot do it now, memory is busy with prefetch)
        refetch_addr      = alu_out;
        refetch_rw        = load_store & store;

$$if verbose then
if (refetch) {
  //__display("  [refetch from] %h",refetch_addr);
}
$$end
        // attempt to predict read ...
        predicted_addr    = refetch ? alu_out[0,26] : next_pc_p8;
        predicted_correct = 1;
        
        // wait for next instr?
        wait_next_instr = (~refetch & ~do_load_store) | ~instr_ready;

        // prepare a potential store     // Note: it is ok to manipulate ram.data_in as only reads can concurrently occur
        switch (loadStoreOp) {
          case 3b000: { // SB
              switch (alu_out[0,2]) {
                case 2b00: { ram.data_in[ 0,8] = regB[ 0,8]; ram.wmask = 4b0001; }
                case 2b01: { ram.data_in[ 8,8] = regB[ 0,8]; ram.wmask = 4b0010; }
                case 2b10: { ram.data_in[16,8] = regB[ 0,8]; ram.wmask = 4b0100; }
                case 2b11: { ram.data_in[24,8] = regB[ 0,8]; ram.wmask = 4b1000; }
              }
          }
          case 3b001: { // SH
              switch (alu_out[1,1]) {
                case 1b0: { ram.data_in[ 0,16] = regB[ 0,16]; ram.wmask = 4b0011; }
                case 1b1: { ram.data_in[16,16] = regB[ 0,16]; ram.wmask = 4b1100; }
              }
          }
          case 3b010: { // SW
            ram.data_in = regB; ram.wmask = 4b1111;
          }
          default: { ram.data_in = 0; }
        }

        // write result to register
        xregsA.wdata1   = branch_or_jump ? next_pc : alu_out;
        xregsB.wdata1   = branch_or_jump ? next_pc : alu_out;
        xregsA.addr1    = write_rd;
        xregsB.addr1    = write_rd;
        xregsA.wenable1 = instr_ready & (~refetch | jump) & rd_enable;
        xregsB.wenable1 = instr_ready & (~refetch | jump) & rd_enable;
$$if verbose then
if (xregsA.wenable1) {        
//__display("  [regs WRITE] regA[%d]=%h regB[%d]=%h",xregsA.addr1,xregsA.wdata1,xregsB.addr1,xregsB.wdata1);
}
$$end

        // setup decoder and ALU for instruction i+1
        // => decoder starts immediately, ALU on next cycle
        instr             = next_instr;
        pc                = next_pc;
$$if verbose then
//__display("  [instr ready:%b] PC set to @%h <<%h>>,  next @%h",instr_ready,next_pc,instr,next_pc+4);
$$end
        next_pc     = (branch_or_jump & instr_ready) ? refetch_addr : next_pc_p4;
$$if verbose then
//__display("  [decode] NEXT PC @%h",next_pc);        
$$end
//__display("[instr setup] %h @%h",instr,pc);
        regA  = ((xregsA.addr0 == xregsA.addr1) & xregsA.wenable1) ? xregsA.wdata1 : xregsA.rdata0;
        regB  = ((xregsB.addr0 == xregsB.addr1) & xregsB.wenable1) ? xregsB.wdata1 : xregsB.rdata0;   
$$if verbose then
  //__display("[regs READ] regA[%d]=%h (%h) regB[%d]=%h (%h)",xregsA.addr0,regA,xregsA.rdata0,xregsB.addr0,regB,xregsB.rdata0);        
$$end

       if (instr_ready) {
         instret = instret + 1;
       }
       instr_ready       = 1;

$$if SIMULATION then          
//      if (retire) {
//          __display("========> [retired instruction] *** %d since ***",cycle-cycle_last_retired);
//          cycle_last_retired = cycle;
//      }
$$end          
      }
    } // switch
        
    cycle           = cycle + 1;

  } // while
}

// --------------------------------------------------
// decode next instruction

algorithm decode(
  input  uint32  instr,
  input  uint26  pc,
  input  int32   regA,
  input  int32   regB,
  output uint5   write_rd,
  output uint1   jump,
  output uint1   branch,
  output uint1   load_store,
  output uint1   store,
  output uint3   loadStoreOp,
  output uint3   select,
  output uint1   sub,
  output uint1   signedShift,
  output uint1   pcOrReg,
  output uint1   regOrImm,
  output uint3   csr,
  output uint1   rd_enable,
  output int32   aluA,
  output int32   aluB,
  output int32   imm,
) <autorun> {

  int32 imm_u  := {Utype(instr).imm31_12,12b0};
  int32 imm_j  := {
           {12{Jtype(instr).imm20}},
           Jtype(instr).imm_19_12,
           Jtype(instr).imm11,
           Jtype(instr).imm10_1,
           1b0};
  int32 imm_i  := {{20{instr[31,1]}},Itype(instr).imm};
  int32 imm_b  :=  {
            {20{Btype(instr).imm12}},
            Btype(instr).imm11,
            Btype(instr).imm10_5,
            Btype(instr).imm4_1,
            1b0
            };
  int32 imm_s  := {{20{instr[31,1]}},Stype(instr).imm11_5,Stype(instr).imm4_0};
  
  uint5 opcode := instr[ 2, 5];
  
  uint1 AUIPC  := opcode == 5b00101;
  uint1 LUI    := opcode == 5b01101;
  uint1 JAL    := opcode == 5b11011;
  uint1 JALR   := opcode == 5b11001;
  uint1 Branch := opcode == 5b11000;
  uint1 Load   := opcode == 5b00000;
  uint1 Store  := opcode == 5b01000;
  uint1 IntImm := opcode == 5b00100;
  uint1 IntReg := opcode == 5b01100;
  uint1 CSR    := opcode == 5b11100;

  uint1 no_rd  := (Branch | Store);

  jump         := (JAL | JALR);
  branch       := (Branch);
  store        := (Store);
  load_store   := (Load | Store);
  regOrImm     := (IntReg);
  select       := (IntImm | IntReg) ? Itype(instr).funct3 : 3b000;
  sub          := (IntReg & Rtype(instr).select2);
  signedShift  := IntImm & instr[30,1]; /*SRLI/SRAI*/

  loadStoreOp  := Itype(instr).funct3;

  csr          := {CSR,instr[20,2]}; // we grab only the bits for 
               // low bits of rdcycle (0xc00), rdtime (0xc01), instret (0xc02)

  write_rd     := Rtype(instr).rd;
  rd_enable    := (write_rd != 0) & ~no_rd;  
  
  pcOrReg      := (AUIPC | JAL | Branch);

  aluA         := (LUI) ? 0 : regA; // ((AUIPC | JAL | Branch) ? __signed({6b0,pc[0,26]}) : regA);
  aluB         := regB;

  always {

    switch (opcode)
     {
      case 5b00101: { // AUIPC
        imm         = imm_u;
       }
      case 5b01101: { // LUI
        imm         = imm_u;
       }
      case 5b11011: { // JAL
        imm         = imm_j;
       }
      case 5b11001: { // JALR
        imm         = imm_i;
       }
      case 5b11000: { // branch
        imm         = imm_b;
       }
      case 5b00000: { // load
        imm         = imm_i;
       }
      case 5b01000: { // store
        imm         = imm_s;
       }
      case 5b00100: { // integer, immediate
        imm         = imm_i;
       }
       default: {
       }
     }

// __display("DECODE %d %d",regA,regB);
    // switch ({AUIPC,LUI,JAL,JALR,Branch,Load,Store,IntImm})
    // {    
    //   case 8b10000000: { // AUIPC
    //     imm         = imm_u;
    //   }
    //   case 8b01000000: { // LUI
    //     imm        = imm_u;
    //   }
    //   case 8b00100000: { // JAL
    //     imm        = imm_j;
    //   }
    //   case 8b00010000: { // JALR
    //     imm        = imm_i;
    //   }
    //   case 8b00001000: { // branch
    //     imm        = imm_b;
    //   } 
    //   case 8b00000100: { // load
    //     imm        = imm_i;
    //   }      
    //   case 8b00000010: { // store
    //     imm        = imm_s;
    //   }
    //   case 8b00000001: { // integer, immediate  
    //     imm        = imm_i;
    //   }
    //   default: { }
    // }

    // switch ({AUIPC|LUI,JAL,JALR|Load|IntImm,Branch,Store})
    // {    
    //   case 5b10000: {
    //     aluB        = imm_u;
    //   }
    //   case 5b01000: {
    //     aluB        = imm_j;
    //   }
    //   case 5b00100: {
    //     aluB        = imm_i;
    //   }
    //   case 5b00010: {
    //     aluB        = imm_b;
    //   } 
    //   case 5b00001: {
    //     aluB        = imm_s;
    //   }
    //   default: {
    //     aluB        = regB;
    //   }
    // }

    // if (AUIPC|LUI) {
    //   aluB        = imm_u;
    // } else {
    //   if (JALR|Load|IntImm) {
    //     aluB        = imm_i;
    //   } else {
    //     if (JAL) {
    //       aluB        = imm_j;
    //     } else {
    //       if (Branch) {
    //         aluB        = imm_b;
    //       } else {
    //         if (Store) {
    //           aluB        = imm_s;
    //         } else {
    //          aluB        = regB; 
    //         }
    //       }
    //     }        
    //   }
    // }

  }
}

// --------------------------------------------------
// Performs integer computations

algorithm intops(
  input!  uint26 pc,
  input!  int32  xa,
  input!  int32  xb,
  input!  int32  imm,
  input!  uint3  select,
  input!  uint1  select2,
  input!  uint1  pcOrReg,
  input!  uint1  regOrImm,
  input!  uint1  sub,
  input!  uint1  signedShift,
  input!  uint3  csr,
  input!  uint32 cycle,
  input!  uint32 instret,
  input!  uint32 user_data,
  output  int32  r,
  input!  int32 ra,
  input!  int32 rb,
  input!  uint3 funct3,
  input!  uint1 branch,
  input!  uint1 jump,
  output  uint1 j,
  output  int32 w,
) {
  
  // 3 cases
  // reg +/- reg (intops)
  // reg +/- imm (intops)
  // pc  + imm   (else)
  
  int32 a := pcOrReg  ? __signed({6b0,pc[0,26]}) : xa;
  int32 b := regOrImm ? (xb) : imm;

  always { // this part of the algorithm is executed every clock  
    switch ({select}) {
      case 3b000: { // ADD / SUB
        // r = a + (sub ? -b : b); // smaller, slower...
        r = sub ? (a - b) : (a + b);
      }
      case 3b010: { // SLTI
        if (__signed(xa)   < __signed(b)) { r = 32b1; } else { r = 32b0; }
      }
      case 3b011: { // SLTU
        if (__unsigned(xa) < __unsigned(b)) { r = 32b1; } else { r = 32b0; }
      }
      case 3b100: { r = xa ^ b;} // XOR
      case 3b110: { r = xa | b;} // OR
      case 3b111: { r = xa & b;} // AND
      case 3b001: { r = (xa <<< b[0,5]); } // SLLI
      case 3b101: { r = signedShift ? (xa >>> b[0,5]) : (xa >> b[0,5]); } // SRLI / SRAI
      default: { }
    }
    if (csr[2,1]) {
    switch (csr[0,2]) {
      case 2b00: { r = cycle;     }
      case 2b01: { r = user_data; }
      case 2b10: { r = instret;   }
      default: { }
    }
    }
    switch (funct3) {
      case 3b000: { j = jump | (branch & (ra == rb)); } // BEQ
      case 3b001: { j = jump | (branch & (ra != rb)); } // BNE
      case 3b100: { j = jump | (branch & (__signed(ra)   <  __signed(rb)));   } // BLT
      case 3b110: { j = jump | (branch & (__unsigned(ra) <  __unsigned(rb))); } // BLTU
      case 3b101: { j = jump | (branch & (__signed(ra)   >= __signed(rb)));   } // BGE
      case 3b111: { j = jump | (branch & (__unsigned(ra) >= __unsigned(rb))); } // BGEU
      default:    { j = jump; }
    }

  }
}

// --------------------------------------------------