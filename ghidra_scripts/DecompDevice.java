// Resolve the shared input/command device (DAT_00574798) vtable ABI.
// 1) Decompile the single writer FUN_004b7b60 to find the concrete class / vtable.
// 2) Find candidate vtables (refs to the writer-stored ctor) and dump slots.
// 3) For the 8 used slots, report callconv, stackPurge(ret N), signature, decompile, and RET tail.
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.symbol.Reference;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.HashSet;
import java.util.Set;

public class DecompDevice extends GhidraScript {
    PrintWriter w;
    DecompInterface decomp;
    Set<Long> dumped = new HashSet<>();

    int readPtr(long a) throws Exception {
        return currentProgram.getMemory().getInt(toAddr(a));
    }

    void decompFn(long fa, String tag) throws Exception {
        Function f = getFunctionAt(toAddr(fa));
        if (f == null) f = createFunction(toAddr(fa), null);
        w.println("\n========== " + tag + " @ 0x" + Long.toHexString(fa) + " ==========");
        if (f == null) { w.println("[no fn]"); return; }
        w.println("name=" + f.getName() + " callconv=" + f.getCallingConventionName()
            + " params=" + f.getParameterCount() + " stackPurge(retN)=" + f.getStackPurgeSize()
            + " sig=" + f.getSignature());
        DecompileResults res = decomp.decompileFunction(f, 60, monitor);
        if (res.decompileCompleted() && res.getDecompiledFunction() != null) {
            w.println(res.getDecompiledFunction().getC());
        } else {
            w.println("[decomp failed: " + res.getErrorMessage() + "]");
        }
    }

    // Print every RET in the function and the prologue's first 4 insns.
    void dumpRets(long fa, String tag) throws Exception {
        Function f = getFunctionAt(toAddr(fa));
        w.println("\n---- RET tail for " + tag + " @ 0x" + Long.toHexString(fa) + " ----");
        if (f == null) { w.println("[no fn]"); return; }
        w.println("  stackPurge(retN)=" + f.getStackPurgeSize() + " callconv=" + f.getCallingConventionName());
        Address end = f.getBody().getMaxAddress();
        InstructionIterator it = currentProgram.getListing().getInstructions(toAddr(fa), true);
        int n = 0;
        while (it.hasNext()) {
            Instruction ins = it.next();
            if (ins.getAddress().getOffset() > end.getOffset()) break;
            String m = ins.getMnemonicString().toLowerCase();
            boolean isRet = m.startsWith("ret");
            if (n < 4 || isRet) {
                w.println(String.format("  0x%08x %s", ins.getAddress().getOffset(), ins.toString()));
            }
            n++;
        }
    }

    void dumpVtableSlots(long vtbl, String tag) throws Exception {
        w.println("\n=== VTABLE " + tag + " @ 0x" + Long.toHexString(vtbl) + " ===");
        for (int i = 0; i < 24; i++) {
            long slotAddr = vtbl + i * 4;
            long fnAddr;
            try { fnAddr = readPtr(slotAddr) & 0xFFFFFFFFL; } catch (Exception e) { break; }
            if (fnAddr < 0x400000 || fnAddr > 0x600000) { w.println(String.format("  [%2d] (+0x%02x) 0x%08x <not-code>", i, i*4, fnAddr)); continue; }
            Function f = getFunctionAt(toAddr(fnAddr));
            String fname = (f != null) ? f.getName() : "<no-fn>";
            String purge = (f != null) ? ("retN=" + f.getStackPurgeSize()) : "";
            w.println(String.format("  [%2d] (+0x%02x) 0x%08x %s %s", i, i*4, fnAddr, fname, purge));
        }
    }

    @Override
    public void run() throws Exception {
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_device.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        // (1) The single writer / setup of the device.
        decompFn(0x004b7b60L, "WRITER FUN_004b7b60 (sets DAT_00574798)");

        // (2) Try to read the runtime vtable pointer directly from the global object,
        //     if the global has an initialized value in the binary (often 0 until runtime).
        long devObjPtr = 0;
        try { devObjPtr = readPtr(0x00574798L) & 0xFFFFFFFFL; } catch (Exception e) {}
        w.println("\n[DAT_00574798 static value in image] = 0x" + Long.toHexString(devObjPtr));
        if (devObjPtr >= 0x400000 && devObjPtr < 0x600000) {
            long vt = readPtr(devObjPtr) & 0xFFFFFFFFL;
            w.println("[*(DAT_00574798) static vtable] = 0x" + Long.toHexString(vt));
            dumpVtableSlots(vt, "from-static-obj");
        }

        // (3) Scan the writer function for any 0x55xxxx data pointer it stores
        //     (the new object's vtable is written by the class ctor; the writer
        //     likely news a class and stores it). We collect all data refs.
        w.println("\n=== Data/const refs out of writer FUN_004b7b60 ===");
        Function wf = getFunctionAt(toAddr(0x004b7b60L));
        Set<Long> vtblCandidates = new HashSet<>();
        if (wf != null) {
            InstructionIterator it = currentProgram.getListing().getInstructions(wf.getBody(), true);
            while (it.hasNext()) {
                Instruction ins = it.next();
                for (int oi = 0; oi < ins.getNumOperands(); oi++) {
                    Object[] objs = ins.getOpObjects(oi);
                    for (Object o : objs) {
                        if (o instanceof ghidra.program.model.scalar.Scalar) {
                            long v = ((ghidra.program.model.scalar.Scalar)o).getUnsignedValue();
                            if (v >= 0x550000 && v < 0x580000) {
                                w.println(String.format("  0x%08x %s -> const 0x%08x", ins.getAddress().getOffset(), ins.toString(), v));
                                vtblCandidates.add(v);
                            }
                        }
                    }
                }
                // also follow call targets (ctors) to see what vtable they install
            }
        }

        // (4) For each candidate that looks like a vftable (its [0] is code), dump it.
        for (long c : vtblCandidates) {
            try {
                long s0 = readPtr(c) & 0xFFFFFFFFL;
                if (s0 >= 0x400000 && s0 < 0x500000 && getFunctionAt(toAddr(s0)) != null) {
                    dumpVtableSlots(c, "candidate-0x" + Long.toHexString(c));
                }
            } catch (Exception e) {}
        }

        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_device.txt");
    }
}
