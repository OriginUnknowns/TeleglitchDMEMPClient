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

public class InvestigatePlayer extends GhidraScript {
    PrintWriter w; DecompInterface decomp;
    void d(long a, String tag) throws Exception {
        Function f=getFunctionAt(toAddr(a)); if(f==null)f=createFunction(toAddr(a),null);
        if(f==null){w.println("[no fn @0x"+Long.toHexString(a)+"]");return;}
        w.println("\n===== "+tag+" "+f.getName()+" @ 0x"+Long.toHexString(a)+" =====");
        DecompileResults r=decomp.decompileFunction(f,60,monitor);
        if(r.decompileCompleted()&&r.getDecompiledFunction()!=null)w.println(r.getDecompiledFunction().getC());
        else w.println("[fail]");
    }
    @Override public void run() throws Exception {
        w=new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_player_mgmt.txt"));
        decomp=new DecompInterface(); decomp.openProgram(currentProgram);

        // Find "GetPlayer" and "CreatePlayer" strings -> registrar -> the cfunc
        DataIterator dit=currentProgram.getListing().getDefinedData(true);
        long getP=0;
        while(dit.hasNext()){ Data dt=dit.next();
            StringDataInstance s=StringDataInstance.getStringDataInstance(dt);
            if(s==null||s==StringDataInstance.NULL_INSTANCE)continue;
            String v=s.getStringValue(); if(v==null)continue;
            if(v.equals("GetPlayer")) getP=dt.getAddress().getOffset();
        }
        w.println("GetPlayer str @ 0x"+Long.toHexString(getP));
        if(getP!=0) for(Reference r:currentProgram.getReferenceManager().getReferencesTo(toAddr(getP))){
            Function f=getFunctionContaining(r.getFromAddress());
            if(f!=null){ d(f.getEntryPoint().getOffset(),"registrar-near-GetPlayer"); break; }
        }
        // CreatePlayer binding + TPlayer ctor + the post-ctor call
        d(0x00425b20L, "CreatePlayer binding");
        d(0x0045b410L, "TPlayer ctor");
        d(0x004b3a90L, "post-ctor call (CreatePlayer)");
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_player_mgmt.txt");
    }
}
