import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.data.StringDataInstance;
import ghidra.program.model.symbol.Reference;
import java.io.FileWriter;
import java.io.PrintWriter;

public class FindSetAction extends GhidraScript {
    PrintWriter w; DecompInterface decomp;
    void d(long a, String tag) throws Exception {
        Function f = getFunctionContaining(toAddr(a));
        if (f==null) f=getFunctionAt(toAddr(a));
        if (f==null){w.println("[no fn @0x"+Long.toHexString(a)+"]");return;}
        w.println("\n===== "+tag+" -> "+f.getName()+" @ 0x"+Long.toHexString(f.getEntryPoint().getOffset())+" =====");
        DecompileResults r=decomp.decompileFunction(f,60,monitor);
        if(r.decompileCompleted()&&r.getDecompiledFunction()!=null)w.println(r.getDecompiledFunction().getC());
        else w.println("[fail]");
    }
    @Override public void run() throws Exception {
        w=new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_setaction.txt"));
        decomp=new DecompInterface(); decomp.openProgram(currentProgram);
        // find "SetAction" string, its registrar (lua_setfield), and the cfunc
        DataIterator dit=currentProgram.getListing().getDefinedData(true);
        long sa=0, ga=0;
        while(dit.hasNext()){
            Data dt=dit.next();
            StringDataInstance sdi=StringDataInstance.getStringDataInstance(dt);
            if(sdi==null||sdi==StringDataInstance.NULL_INSTANCE)continue;
            String s=sdi.getStringValue(); if(s==null)continue;
            if(s.equals("SetAction")) sa=dt.getAddress().getOffset();
            if(s.equals("GetAction")) ga=dt.getAddress().getOffset();
        }
        w.println("SetAction str @ 0x"+Long.toHexString(sa)+"  GetAction str @ 0x"+Long.toHexString(ga));
        // registrar referencing SetAction string
        if(sa!=0) for(Reference r: currentProgram.getReferenceManager().getReferencesTo(toAddr(sa))){
            Function f=getFunctionContaining(r.getFromAddress());
            if(f!=null){ d(f.getEntryPoint().getOffset(), "registrar-of-SetAction"); break; }
        }
        // Also dump FUN_0045f170 (the per-action animation player) — it tells us
        // how an action maps to/initializes the anim-state object.
        d(0x45f170L, "FUN_0045f170 (per-action anim check/init)");
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_setaction.txt");
    }
}
