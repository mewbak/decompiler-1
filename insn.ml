type 'a operand =
    Hard_reg of int
  | VFP_sreg of int
  | VFP_dreg of int
  | FPSCR
  | Immediate of int32
  | Address of int32
  | PC_relative of int32
  | Stack of int
  | Converted of 'a

and cc_bits = C | V | N | Z
	    | C_zero | C_one | C_from_shift

and condition = Eq | Ne | Cs | Cc | Mi | Pl | Vs | Vc
	      | Hi | Ls | Ge | Lt | Gt | Le

type opcode =
    Ldr of access_info
  | Str of access_info
  | Ldrb of access_info
  | Strb of access_info
  | Ldrh of access_info
  | Strh of access_info
  | Ldrsh of access_info
  | Ldrsb of access_info
  | Strd of access_info
  | Ldrd of access_info
  | And
  | Eor
  | Sub
  | Rsb
  | Add
  | Adc
  | Sbc
  | Rsc
  | Tst
  | Teq
  | Cmp
  | Cmn
  | Orr
  | Mov
  | Bic
  | Mvn
  | B
  | Bl
  | Bx
  | Ldm of multimem_info
  | Stm of multimem_info
  | Mul
  | Mla
  | Umaal
  | Mls
  | Umull
  | Umlal
  | Smull
  | Smlal
  | Uxtb
  | Uxth
  | Sxtb
  | Sxth
  | Sbfx
  | Ubfx
  | Bfc
  | Bfi
  | Vmov_f2rr
  | Vmov_rr2f
  | Vmov_r2d_lo
  | Vmov_r2d_hi
  | Vmov_d2r_lo
  | Vmov_d2r_hi
  | Vmov_r2f
  | Vmov_f2r
  | Vmov_imm
  | Vmov_reg
  | Vstr
  | Vldr
  | Vmla
  | Vnmla
  | Vmls
  | Vnmls
  | Vmul
  | Vnmul
  | Vadd
  | Vsub
  | Vdiv
  | Vabs
  | Vneg
  | Vsqrt
  | Vcmp
  | Vcmpe
  | Vcvt_f2d
  | Vcvt_d2f
  | Vcvt_f2si
  | Vcvt_f2ui
  | Vcvtr_f2si
  | Vcvtr_f2ui
  | Vcvt_si2f
  | Vcvt_ui2f
  | Vmsr
  | Vmrs
  | Vstm of multimem_info
  | Vldm of multimem_info
  | Shifted of opcode * shift_opcode
  | Conditional of condition * opcode
  | BAD

and shift_opcode =
    Lsl
  | Lsr
  | Asr
  | Ror
  | Rrx

and addr_mode =
    Base_plus_imm
  | Base_plus_reg
  | Base_minus_reg
  | Base_plus_shifted_reg of shift_opcode
  | Base_minus_shifted_reg of shift_opcode

and access_info =
  {
    addr_mode : addr_mode;
    writeback : bool;
    pre_modify : bool
  }

and multimem_info =
  {
    before : bool;
    increment : bool;
    mm_writeback : bool
  }

type 'a insn =
  {
    opcode : opcode;
    write_operands : 'a operand array;
    read_operands : 'a operand array;
    write_flags : cc_bits list;
    (* READ_FLAGS does *not* count flags required by insn
       conditionalisation!  *)
    read_flags : cc_bits list;
    clobber_flags : cc_bits list
  }
