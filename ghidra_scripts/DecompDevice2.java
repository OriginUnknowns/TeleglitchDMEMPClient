// Step 2: the device ctor FUN_004baca0 installs the vtable. Find it, dump the 8
// used slots' methods with callconv + stackPurge(retN) + signature + decomp + RET tail.
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.HashSet;
import java.util.Set;
import java.util.TreeSet;

public class DecompDevice2 extends GhidraScript {
    PrintWriter w;
    DecompInterface decomp;

    long readPtr(long a) throws Exception {
        return currentProgram.getMemory().getInt(toAddr(a)) & 0xFFFFFFFFL;
    }

    void hdr(long fa, String tag) throws Exception {
        Function f = getFunctionAt(toAddr(fa));
        if (f == null) f = createFunction(toAddr(fa), null);
        w.println("\n========== " + tag + " @ 0x" + Long.toHexString(fa) + " ==========");
        if (f == null) { w.println("[no fn]"); return; }
        w.println("name=" + f.getName() + " callconv=" + f.getCallingConventionName()
            + " params=" + f.getParameterCount() + " stackPurge(retN)=" + f.getStackPurgeSize()
            + " sig=" + f.getSignature());
    }

    void decompFn(long fa, String tag) throws Exception {
        hdr(fa, tag);
        Function f = getFunctionAt(toAddr(fa));
        if (f == null) return;
        DecompileResults res = decomp.decompileFunction(f, 60, monitor);
        if (res.decompileCompleted() && res.getDecompiledFunction() != null) {
            w.println(res.getDecompiledFunction().getC());
        } else {
            w.println("[decomp failed: " + res.getErrorMessage() + "]");
        }
    }

    void dumpRets(long fa) throws Exception {
        Function f = getFunctionAt(toAddr(fa));
        if (f == null) { w.println("  [no fn for RET tail]"); return; }
        Address end = f.getBody().getMaxAddress();
        InstructionIterator it = currentProgram.getListing().getInstructions(toAddr(fa), true);
        int n = 0;
        w.println("  -- prologue + all RETs --");
        while (it.hasNext()) {
            Instruction ins = it.next();
            if (ins.getAddress().getOffset() > end.getOffset()) break;
            String m = ins.getMnemonicString().toLowerCase();
            boolean isRet = m.startsWith("ret");
            if (n < 4 || isRet) {
                w.println(String.format("    0x%08x %s", ins.getAddress().getOffset(), ins.toString()));
            }
            n++;
        }
    }

    void dumpVtableSlots(long vtbl, int count) throws Exception {
        w.println("\n=== VTABLE @ 0x" + Long.toHexString(vtbl) + " ===");
        for (int i = 0; i < count; i++) {
            long fnAddr = readPtr(vtbl + i * 4);
            Function f = getFunctionAt(toAddr(fnAddr));
            String fname = (f != null) ? f.getName() : "<no-fn>";
            String purge = (f != null) ? ("retN=" + f.getStackPurgeSize() + " conv=" + f.getCallingConventionName()) : "";
            w.println(String.format("  [%2d] (+0x%02x) 0x%08x %s %s", i, i*4, fnAddr, fname, purge));
        }
    }

    @Override
    public void run() throws Exception {
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_device2.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        // (1) decompile the ctor; it stores the vtable pointer into [this].
        decompFn(0x004baca0L, "DEVICE CTOR FUN_004baca0");

        // (2) scan the ctor for the immediate vtable address it MOVs into [reg] / [this].
        //     The vtable global lives in 0x55xxxx..0x56xxxx. The FIRST such const whose
        //     [0] is a code pointer is the installed vftable.
        w.println("\n=== const refs in ctor FUN_004baca0 (vtable candidates) ===");
        Function cf = getFunctionAt(toAddr(0x004baca0L));
        TreeSet<Long> cands = new TreeSet<>();
        if (cf != null) {
            InstructionIterator it = currentProgram.getListing().getInstructions(cf.getBody(), true);
            while (it.hasNext()) {
                Instruction ins = it.next();
                for (int oi = 0; oi < ins.getNumOperands(); oi++) {
                    for (Object o : ins.getOpObjects(oi)) {
                        if (o instanceof ghidra.program.model.scalar.Scalar) {
                            long v = ((ghidra.program.model.scalar.Scalar)o).getUnsignedValue();
                            if (v >= 0x540000 && v < 0x580000) {
                                w.println(String.format("  0x%08x %s -> 0x%08x", ins.getAddress().getOffset(), ins.toString(), v));
                                cands.add(v);
                            }
                        }
                    }
                }
            }
        }

        long vtable = 0;
        for (long c : cands) {
            try {
                long s0 = readPtr(c);
                Function f0 = getFunctionAt(toAddr(s0));
                if (s0 >= 0x400000 && s0 < 0x500000 && f0 != null) {
                    w.println("  -> candidate 0x" + Long.toHexString(c) + " has code at [0]=0x" + Long.toHexString(s0) + " (LIKELY VTABLE)");
                    if (vtable == 0) vtable = c;
                }
            } catch (Exception e) {}
        }

        if (vtable == 0) {
            w.println("\n[!] No vtable const found directly in ctor. Dumping all candidates' slot[0..1].");
            for (long c : cands) {
                try { w.println("  0x" + Long.toHexString(c) + " [0]=0x" + Long.toHexString(readPtr(c))); } catch (Exception e) {}
            }
        } else {
            dumpVtableSlots(vtable, 20);
            // (3) The 8 used slots (byte offsets / 4 = index)
            int[] used = {0x0, 0x4, 0x8, 0xc, 0x10, 0x14, 0x1c, 0x44};
            for (int boff : used) {
                long fnAddr = readPtr(vtable + boff);
                String tag = "SLOT +0x" + Integer.toHexString(boff);
                decompFn(fnAddr, tag);
                dumpRets(fnAddr);
            }
        }

        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_device2.txt vtable=0x" + Long.toHexString(vtable));
    }
}
