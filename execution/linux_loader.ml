(*
 Owned and copyright BitBlaze, 2009-2010. All rights reserved.
 Do not copy, disclose, or distribute without explicit written
 permission.
*)

open Concrete_domain;;
open Exec_options;;
open Fragment_machine;;
open Linux_syscalls;;

type elf_header = {
  eh_type : int;
  machine : int;
  version : int64;
  entry : int64;
  phoff : int64;
  shoff : int64;
  eh_flags : int64;
  ehsize : int;
  phentsize : int;
  phnum : int;
  shentsize : int;
  shnum : int;
  shstrndx : int
}

(* "Program header" is the standard ELF terminology, but it would be
   more natural to call this a "segment header". (However the
   abbreviation "SH" in ELF always stands for "section header", which
   is something else.) *)
type program_header = {
  ph_type : int64;
  offset : int64;
  vaddr : int64;
  paddr : int64;
  filesz : int64;
  memsz : int64;
  ph_flags : int64;
  align : int64
}
      
let seen_pc = ref false

let check_single_start_eip pc =
  if (!seen_pc) 
  then (failwith ("The process start state (core file) has more than one start eip. Please consider specifying the -pid option.")) 
  else (seen_pc := true)
      
let read_ui32 i =
  Int64.logand 0xffffffffL (Int64.of_int32 (IO.read_real_i32 i))

let read_elf_header ic =
  let i = IO.input_channel ic in
  let ident = IO.really_nread i 16 in
    assert(ident = 
	"\x7fELF\001\001\001\000\000\000\000\000\000\000\000\000");
    (* OCaml structure initialization isn't guaranteed to happen
       left to right, so we need to use a bunch of lets here: *)
    let eh_type = IO.read_ui16 i in
    let machine = IO.read_ui16 i in
    let version = read_ui32 i in
    let entry = read_ui32 i in
    let phoff = read_ui32 i in
    let shoff = read_ui32 i in
    let eh_flags = read_ui32 i in
    let ehsize = IO.read_ui16 i in
    let phentsize = IO.read_ui16 i in
    let phnum = IO.read_ui16 i in
    let shentsize = IO.read_ui16 i in
    let shnum = IO.read_ui16 i in
    let shstrndx = IO.read_ui16 i in
    let eh = {
      eh_type = eh_type; machine = machine; version = version;
      entry = entry; phoff = phoff; shoff = shoff; eh_flags = eh_flags;
      ehsize = ehsize; phentsize = phentsize; phnum = phnum;
      shentsize = shentsize; shnum = shnum; shstrndx = shstrndx }
    in
      assert(eh.ehsize = 16 + 36);
      eh

let read_program_headers ic eh =
  assert(eh.phentsize = 32);
  seek_in ic (Int64.to_int eh.phoff);
  let i = IO.input_channel ic in
    ExtList.List.init eh.phnum
      (fun _ -> 
	 let ph_type = read_ui32 i in
	 let offset = read_ui32 i in
	 let vaddr = read_ui32 i in
	 let paddr = read_ui32 i in
	 let filesz = read_ui32 i in
	 let memsz = read_ui32 i in
	 let ph_flags = read_ui32 i in
	 let align = read_ui32 i in
	   { ph_type = ph_type; offset = offset; vaddr = vaddr;
	     paddr = paddr; filesz = filesz; memsz = memsz;
	     ph_flags = ph_flags;
	     align = align
	   })

let store_page fm vaddr str =
  if Int64.rem vaddr 0x1000L = 0L && (String.length str) = 4096 then
    fm#store_page_conc vaddr str
  else
    fm#store_str vaddr 0L str

let load_segment fm ic phr virt_off =
  let i = IO.input_channel ic in
  let type_str = match (phr.ph_type, phr.ph_flags) with
    | (1L, 5L) -> "text"
    | (1L, 6L)
    | (1L, 7L) -> "data"
    | (1L, flags) -> (Printf.sprintf "LOAD:%08Lx" flags)
    | (2L, _) -> "DYNAMIC"
    | (3L, _) -> "INTERP"
    | (4L, _) -> "NOTE"
    | (6L, _) -> "PHDR"
    | (7L, _) -> "TLS"
    | (0x6474e550L, _) -> "EH_FRAME"
    | (0x6474e551L, _) -> "STACK"
    | (0x6474e552L, _) -> "RELRO"
    | (ty, flags) -> (Printf.sprintf "??? %08Lx:%08Lx" ty flags)
  in
  let partial = Int64.rem phr.filesz 0x1000L in
  let vbase = Int64.add phr.vaddr virt_off in
    if !opt_trace_setup then
      Printf.printf "Loading %8s segment from %08Lx to %08Lx\n"
	type_str vbase
	(Int64.add vbase phr.filesz);
    seek_in ic (Int64.to_int phr.offset);
    for page_num = 0 to (Int64.to_int (Int64.div phr.filesz 4096L)) - 1 do
      let page = IO.really_nread i 4096 and
	  va = (Int64.add vbase
		  (Int64.mul (Int64.of_int page_num) 4096L)) in
	store_page fm va page
    done;
    (if partial <> 0L then
       let page = IO.really_nread i (Int64.to_int partial) and
	   va = (Int64.add vbase
		   (Int64.sub phr.filesz partial)) in
	 store_page fm va page);
    if phr.memsz > phr.filesz && type_str = "data" then
      (* E.g., a BSS region. Zero fill to avoid uninit-value errors. *)
      (if !opt_trace_setup then
	 Printf.printf "            Zero filling from %08Lx to %08Lx\n"
	   (Int64.add vbase phr.filesz) (Int64.add vbase phr.memsz);
       let va = ref (Int64.add vbase phr.filesz) in
       let first_full = (Int64.logand (Int64.add !va 4095L)
			   (Int64.lognot 4095L)) in
       let remaining = ref (Int64.sub phr.memsz phr.filesz) in
       let partial1 = min (Int64.sub first_full !va) !remaining in
	 fm#zero_fill !va (Int64.to_int partial1);
	 va := Int64.add !va partial1;
	 remaining := Int64.sub !remaining partial1;
	 while !remaining >= 4096L do
	   store_page fm !va (String.make 4096 '\000');
	   va := Int64.add !va 4096L;
	   remaining := Int64.sub !remaining 4096L
	 done;
	 fm#zero_fill !va (Int64.to_int !remaining);
	 va := Int64.add !va !remaining;
	 (* ld.so knows that it can use beyond its BSS to the end of
	    the page that it's stored on as the first part of its heap
	    without asking from an allocation from the OS. So 0-fill
	    the rest of the page too to be compatible with this. *)
	 let last_aligned = (Int64.logand (Int64.add !va 4095L)
			       (Int64.lognot 4095L)) in
	   if !opt_trace_setup then
	     Printf.printf "      Extra zero filling from %08Lx to %08Lx\n"
	       !va last_aligned;
	   (if last_aligned < 0xb7f00000L then
	      match !linux_initial_break with 
		| None -> linux_initial_break := Some last_aligned;
		    if !opt_trace_setup then
		      Printf.printf "Setting initial break to 0x%08Lx\n"
			last_aligned;
		| _ -> ())	;
	   let last_space = Int64.to_int (Int64.sub last_aligned !va) in
	     fm#zero_fill !va last_space)

let load_partial_segment fm ic phr vbase size =
  let i = IO.input_channel ic in
  let file_base = Int64.sub vbase phr.vaddr in
    if !opt_trace_setup then
      Printf.printf "Loading     extra region from %08Lx to %08Lx\n"
	vbase (Int64.add vbase size);
    assert(size <= 4096L);
    assert((Int64.add file_base size) <= phr.filesz);
    seek_in ic (Int64.to_int (Int64.add phr.offset file_base));
    let data = IO.really_nread i (Int64.to_int size) in
      store_page fm vbase data;
      fm#watchpoint
	  
let load_ldso fm dso vaddr =
  let ic = open_in dso in
  let dso_eh = read_elf_header ic in
    if !opt_trace_setup then
      Printf.printf "Loading from dynamic linker %s\n" dso;
    assert(dso_eh.eh_type = 3);
    List.iter
      (fun phr ->
	 if phr.ph_type = 1L || phr.memsz <> 0L then
	   load_segment fm ic phr vaddr)
      (read_program_headers ic dso_eh);
    close_in ic;
    Int64.add vaddr dso_eh.entry

let build_startup_state fm eh load_base ldso argv =
  let esp = ref 0xc0000000L in
  let push_cstr s =
    esp := Int64.sub !esp (Int64.of_int ((String.length s) + 1));
    fm#store_cstr !esp 0L s;
    !esp
  in
  let push_word i =
    esp := Int64.sub !esp 4L;
    fm#store_word_conc !esp i
  in
  let env_keys = Vine_util.list_unique
    (Hashtbl.fold (fun k v l -> k :: l) opt_extra_env []) @
    ["DISPLAY"; "EDITOR"; "HOME"; "LANG"; "LOGNAME"; "PAGER"; "PATH";
     "PWD"; "SHELL"; "TERM"; "USER"; "USERNAME"; "XAUTHORITY"] in
  let env = List.concat
    (List.map
       (fun key -> 
	  if Hashtbl.mem opt_extra_env key then
	    (if !opt_trace_setup then
	       Printf.printf "From command line, setting env. var %s to %s\n"
		 key (Hashtbl.find opt_extra_env key);
	     [key ^ "=" ^ (Hashtbl.find opt_extra_env key)])
	  else
	    try
	      let v = Sys.getenv key in
		if !opt_trace_setup then
		  Printf.printf "From real env., setting env. var %s to %s\n"
		    key v;
		[key ^ "=" ^ v]
	    with
		Not_found -> 
		  if !opt_trace_setup then
		    Printf.printf "Skipping missing env. var %s\n" key;
		  [])
       env_keys)
  in
  let env_locs = List.map push_cstr env in
  let argv_locs = List.map push_cstr argv in
  let platform_loc = push_cstr "i686" in
  let auxv =
    [(3L, Int64.add load_base eh.phoff);    (* AT_PHDR *)
     (4L, Int64.of_int eh.phentsize);       (* AT_PHENT *)
     (5L, Int64.of_int eh.phnum);           (* AT_PHNUM *)
     (6L, 4096L);                           (* AT_PAGESZ *)
     (7L, ldso);                            (* AT_BASE: dynamic loader *)
     (8L, 0L);                              (* AT_FLAGS, no flags *)
     (9L, eh.entry);                        (* AT_ENTRY *)
     (11L, Int64.of_int (Unix.getuid ()));  (* AT_UID *)
     (12L, Int64.of_int (Unix.geteuid ())); (* AT_EUID *)
     (13L, Int64.of_int (Unix.getgid ()));  (* AT_GID *)
     (14L, Int64.of_int (Unix.getegid ())); (* AT_EGID *)
     (15L, platform_loc);                   (* AT_PLATFORM *)
     (* (16L, 0xbfebfbffL);                    (* AT_HWCAP, Core 2 Duo *) *)
     (16L, 0L);                             (* AT_HWCAP, bare-bones *)
     (17L, 100L);                           (* AT_CLKTCK *)
     (23L, 0L);                             (* AT_SECURE *)
     (* Let's see if we can avoid bothering with AT_SYSINFO *)
    ] in
    esp := Int64.logand !esp (Int64.lognot 0xfL); (* 16-bit align *)
    if (List.length auxv) mod 2 = 1 then
      (push_word 0L; push_word 0L);
    List.iter (fun (k, v) -> push_word v; push_word k) auxv;
    push_word 0L; (* 0 byte marking end of environment *)
    List.iter push_word env_locs;
    push_word 0L; (* 0 byte marking end of argv *)
    List.iter push_word (List.rev argv_locs);
    push_word (Int64.of_int (List.length argv)); (* argc *)
    if !opt_trace_setup then
      Printf.printf "Initial ESP is 0x%08Lx\n" !esp;
    fm#set_word_var R_ESP !esp      

let load_dynamic_program (fm : fragment_machine) fname load_base
    data_too do_setup extras argv =
  let ic = open_in fname in
  let i = IO.input_channel ic in
  let ldso_base = ref 0L in
  let eh = read_elf_header ic in
  let entry_point = ref eh.entry in
    assert(eh.eh_type = 2);
    entry_point := eh.entry;
    List.iter
      (fun phr ->
	 if phr.ph_type = 1L then (* PT_LOAD *)
	   (if phr.ph_flags = 5L then assert(phr.vaddr = load_base);
	    if data_too || (phr.ph_flags <> 6L && phr.ph_flags <> 7L) then
	      load_segment fm ic phr 0L)
	 else if phr.ph_type = 3L then (* PT_INTERP *)
	   (seek_in ic (Int64.to_int phr.offset);
	    let interp = IO.really_nread i ((Int64.to_int phr.filesz) - 1) in
	    let base = 0xb7f00000L in
	      entry_point := load_ldso fm interp base;
	      ldso_base := base;
	      load_segment fm ic phr 0L)
	 else if phr.memsz != 0L then
	   load_segment fm ic phr 0L;
	 List.iter
	   (fun (base, size) ->
	      if base >= phr.vaddr && 
		base < (Int64.add phr.vaddr phr.memsz)
	      then
		(assert(Int64.add base size < Int64.add phr.vaddr phr.memsz);
		 load_partial_segment fm ic phr base size))
	   extras)
      (read_program_headers ic eh);
    close_in ic;
    if do_setup then
      build_startup_state fm eh load_base !ldso_base argv;
    !entry_point
      
let start_eip = ref 0L

let proc_identities = ref None

let read_core_note fm ic =
  let i = IO.input_channel ic in
  let namesz = IO.read_i32 i in
  let descsz = IO.read_i32 i in
  let ntype = read_ui32 i in
  let namez = IO.really_nread i ((namesz + 3) land (lnot 3)) in
  let name = String.sub namez 0 (namesz - 1) in
  let endpos = pos_in ic + descsz in
    assert(descsz mod 4 = 0);
    if name = "CORE" && ntype = 1L then
      (let si_signo = IO.read_i32 i in
       let si_code = IO.read_i32 i in
       let si_errno = IO.read_i32 i in
       let cursig = read_ui32 i in
       let sigpend = read_ui32 i in
       let sighold = read_ui32 i in
       let pid = IO.read_i32 i in
	 if ((pid = !opt_pid) || (!opt_pid = -1)) then (
	   let ppid = IO.read_i32 i in
	   let pgrp = IO.read_i32 i in
	   let sid = IO.read_i32 i in
	     ignore(IO.really_nread i 32);
	     let ebx = IO.read_real_i32 i in
	     let ecx = IO.read_real_i32 i in
	     let edx = IO.read_real_i32 i in
	     let esi = IO.read_real_i32 i in
	     let edi = IO.read_real_i32 i in
	     let ebp = IO.read_real_i32 i in
	     let eax = IO.read_real_i32 i in
	     let xds = IO.read_real_i32 i in
	     let xes = IO.read_real_i32 i in
	     let xfs = IO.read_real_i32 i in
	     let xgs = IO.read_real_i32 i in
	     let orig_eax = IO.read_real_i32 i in
	     let eip = IO.read_real_i32 i in
	     let () = check_single_start_eip (fix_u32 (Int64.of_int32 eip))
	     in
	     let xcs = IO.read_real_i32 i in
	     let eflags = IO.read_real_i32 i in
	     let esp = IO.read_real_i32 i in
	     let xss = IO.read_real_i32 i in
	     let user_regs =
	       { Temu_state.eax = eax; Temu_state.ebx = ebx;
		 Temu_state.ecx = ecx; Temu_state.edx = edx;
		 Temu_state.esi = esi; Temu_state.edi = edi;
		 Temu_state.ebp = ebp; Temu_state.esp = esp;
		 Temu_state.eip = eip; Temu_state.eflags = eflags;
		 Temu_state.xcs = xcs; Temu_state.xds = xds;
		 Temu_state.xes = xes; Temu_state.xfs = xfs;
		 Temu_state.xgs = xgs; Temu_state.xss = xss; } in
	       fm#load_x86_user_regs user_regs;
	       start_eip := fix_u32 (Int64.of_int32 eip);
	       proc_identities := Some (pid, ppid, pgrp, sid);
	       ignore(si_signo); ignore(si_code); ignore(si_errno);
	       ignore(cursig); ignore(sigpend); ignore(sighold);
	       ignore(orig_eax)
	 );
      );
    seek_in ic endpos
  
let load_core (fm:fragment_machine) fname =
  let ic = open_in fname in
  let eh = read_elf_header ic in
    assert(eh.eh_type = 4);
    List.iter
      (fun phr ->
	 if phr.ph_type = 1L then (* PT_LOAD *)
	   load_segment fm ic phr 0L
	 else if phr.ph_type = 4L then (* PT_NOTE *)
	   (seek_in ic (Int64.to_int phr.offset);
	    let endpos = Int64.to_int (Int64.add phr.offset phr.filesz) in
	      while pos_in ic < endpos do
		read_core_note fm ic
	      done))
      (read_program_headers ic eh);
    close_in ic;
    !start_eip

let setup_tls_segment (fm:fragment_machine) gdt tls_base =
  let gs_sel = fm#get_short_var R_GS in
    assert(gs_sel land 7 = 3); (* global, ring 3 *)
    linux_setup_tcb_seg fm (gs_sel asr 3) gdt tls_base 0xfffffL;
    (* If this is set up correctly, the first word in the TLS
       segment will be a pointer to itself. *)
    let read_tls_base = fm#load_word_conc tls_base in
      assert(tls_base = read_tls_base);