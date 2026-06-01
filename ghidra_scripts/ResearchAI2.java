import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.mem.Memory;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.HashSet;
import java.util.Set;

public class ResearchAI2 extends GhidraScript {
    PrintWriter w;
    DecompInterface decomp;
    Set<Long> dumped = new HashSet<>();

    void d(long a, String tag) throws Exception {
        if (dumped.contains(a)) { w.println("(already dumped: " + tag + " @ 0x" + Long.toHexString(a) + ")"); return; }
        dumped.add(a);
        Function f = getFunctionAt(toAddr(a));
        if (f == null) f = createFunction(toAddr(a), null);
        if (f == null) { w.println("[no fn at 0x" + Long.toHexString(a) + "]"); return; }
        w.println("\n========== " + tag + " " + f.getName() + " @ 0x" + Long.toHexString(a) + " ==========");
        DecompileResults res = decomp.decompileFunction(f, 120, monitor);
        if (res.decompileCompleted() && res.getDecompiledFunction() != null) {
            w.println(res.getDecompiledFunction().getC());
        } else {
            w.println("[decomp failed]");
        }
        w.flush();
    }

    void findStringRefs(String needle) throws Exception {
        w.println("\n### Strings containing \"" + needle + "\" and their xrefs");
        Memory mem = currentProgram.getMemory();
        Address start = toAddr(0x00500000L);
        Address end = toAddr(0x00580000L);
        byte[] target = needle.getBytes();
        Address cur = start;
        int found = 0;
        while (cur.compareTo(end) < 0 && found < 20) {
            try {
                boolean match = true;
                for (int i = 0; i < target.length; i++) {
                    if (mem.getByte(cur.add(i)) != target[i]) { match = false; break; }
                }
                if (match) {
                    byte nxt = mem.getByte(cur.add(target.length));
                    if (nxt == 0) {
                        StringBuilder sb = new StringBuilder();
                        for (int i = 0; i < 40; i++) {
                            byte b = mem.getByte(cur.add(i));
                            if (b == 0) break;
                            sb.append((char) b);
                        }
                        w.println("  str@0x" + Long.toHexString(cur.getOffset()) + " = \"" + sb + "\"");
                        ReferenceIterator it = currentProgram.getReferenceManager().getReferencesTo(cur);
                        while (it.hasNext()) {
                            Reference r = it.next();
                            Function f = currentProgram.getFunctionManager().getFunctionContaining(r.getFromAddress());
                            String fname = (f != null) ? f.getName() + "@0x" + Long.toHexString(f.getEntryPoint().getOffset()) : "<no-fn>";
                            w.println("    xref from 0x" + Long.toHexString(r.getFromAddress().getOffset()) + " in " + fname);
                        }
                        found++;
                    }
                }
            } catch (Exception e) {}
            cur = cur.add(1);
        }
    }

    @Override
    public void run() throws Exception {
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_ai_research2.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        // The big hits from round 1
        d(0x00462df0L, "AI-dispatch (refs 'aitype', 'basic')");
        d(0x00462040L, "Mob config loader (refs melee*/seeplayer/lostplayer/huntsound)");
        d(0x00467060L, "Refs alertradius + shootfrequency");
        d(0x00456050L, "Refs turnspeed + shootfrequency");
        d(0x00460550L, "Refs turnspeed");
        d(0x00460860L, "Refs turnspeed");
        d(0x00463390L, "Refs movertype");

        // More AI strings
        findStringRefs("attacktype");
        findStringRefs("aggressive");
        findStringRefs("shooter");
        findStringRefs("meleerange");
        findStringRefs("attackrange");
        findStringRefs("sightradius");
        findStringRefs("alarmradius");
        findStringRefs("attackdistance");
        findStringRefs("attackbullet");
        findStringRefs("attacksound");
        findStringRefs("attackanim");
        findStringRefs("attack");
        findStringRefs("aimtime");
        findStringRefs("seeplayer");
        findStringRefs("lostplayer");
        findStringRefs("target");
        findStringRefs("hatedfaction");
        findStringRefs("seen_player");

        // Big xref count for DAT_005747a4 — let's decompile a couple of mob-looking ones to spot AI reads.
        // FUN_00467060 was xref'd 'alertradius' & 'shootfrequency'; that's the mob think/AI.
        // FUN_00462df0 was aitype dispatcher.
        // FUN_004293a0 / FUN_00429410 / FUN_00429fa0 - read DAT_005747a4, possibly mob movement.
        // FUN_0043ced0, FUN_0043d570, FUN_0043d870, FUN_004534e0, FUN_00453e80, FUN_004547c0, FUN_00454e20, FUN_00456ea0,
        // FUN_00458b90, FUN_00459b70, FUN_00459fb0, FUN_0045a1f0, FUN_004952c0 etc.
        d(0x004293a0L, "Reads DAT_005747a4 (player ptr)");
        d(0x00429410L, "Reads DAT_005747a4");
        d(0x00429fa0L, "Reads DAT_005747a4");
        d(0x004293a0L, "Reads DAT_005747a4");

        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_ai_research2.txt");
    }
}
