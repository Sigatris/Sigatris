import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:shared_preferences/shared_preferences.dart';

const targetName = 'Tarczociag_Puszka_BT';

class SettingsStore {
  SettingsStore(this.prefs);
  final SharedPreferences prefs;
  List<int> get distances => [prefs.getInt('d0') ?? 10, prefs.getInt('d1') ?? 25, prefs.getInt('d2') ?? 33, prefs.getInt('d3') ?? 50];
  int get speed => prefs.getInt('speed') ?? 180;
  int get ramp => prefs.getInt('ramp') ?? 20;
  Future<void> saveDistances(List<int> v) async { for (var i=0;i<4;i++) await prefs.setInt('d$i', v[i]); }
  Future<void> saveMotor(int s,int r) async { await prefs.setInt('speed',s); await prefs.setInt('ramp',r); }
}

class BtService {
  BluetoothConnection? connection;
  StreamSubscription<Uint8List>? sub;
  final connected = StreamController<bool>.broadcast();
  final position = StreamController<double>.broadcast();
  final status = StreamController<String>.broadcast();
  String buffer = '';
  bool get isConnected => connection != null;

  Future<List<BluetoothDevice>> bonded() => FlutterBluetoothSerial.instance.getBondedDevices();
  Future<void> connect(BluetoothDevice d) async {
    await disconnect();
    final c = await BluetoothConnection.toAddress(d.address);
    connection = c; connected.add(true);
    sub = c.input?.listen((data) {
      buffer += utf8.decode(data, allowMalformed: true);
      while (buffer.contains('\n')) { final i=buffer.indexOf('\n'); final line=buffer.substring(0,i).trim(); buffer=buffer.substring(i+1); if(line.isNotEmpty) _parse(line); }
      if(buffer.length>4096) buffer=buffer.substring(buffer.length-1024);
    }, onDone: disconnect);
  }
  void _parse(String s) {
    final m=RegExp(r'^POS:([0-9]+(?:\.[0-9]+)?)$').firstMatch(s);
    if(m!=null) { final p=double.tryParse(m.group(1)!); if(p!=null) position.add(p); return; }
    if(s=='STATUS:HOME_OK'||s.startsWith('STATUS:ARRIVED:')||s=='CFG:OK') status.add(s); else status.add(s);
  }
  Future<void> send(String s) async { if(connection==null) throw StateError('Brak połączenia Bluetooth'); connection!.output.add(Uint8List.fromList(utf8.encode(s.endsWith('\n')?s:'$s\n'))); await connection!.output.allSent; }
  Future<void> disconnect() async { await sub?.cancel(); sub=null; try { await connection?.finish(); } catch(_){ } connection=null; connected.add(false); }
  Future<void> dispose() async { await disconnect(); await connected.close(); await position.close(); await status.close(); }
}

void main() async { WidgetsFlutterBinding.ensureInitialized(); final p=await SharedPreferences.getInstance(); runApp(App(store:SettingsStore(p),bt:BtService())); }

class App extends StatelessWidget { const App({super.key,required this.store,required this.bt}); final SettingsStore store; final BtService bt; @override Widget build(BuildContext c)=>MaterialApp(debugShowCheckedModeBanner:false,title:'Tarczociąg',theme:ThemeData(useMaterial3:true,colorSchemeSeed:Colors.indigo),home:Dashboard(store:store,bt:bt)); }

class Dashboard extends StatefulWidget { const Dashboard({super.key,required this.store,required this.bt}); final SettingsStore store; final BtService bt; @override State<Dashboard> createState()=>_DashboardState(); }
class _DashboardState extends State<Dashboard> {
  late List<int> d; double pos=0; bool connected=false; String stat='Brak komunikatów';
  late StreamSubscription a,b,c;
  @override void initState(){super.initState();d=widget.store.distances; a=widget.bt.connected.stream.listen((v)=>setState(()=>connected=v)); b=widget.bt.position.stream.listen((v)=>setState(()=>pos=v)); c=widget.bt.status.stream.listen((v)=>setState(()=>stat=v)); WidgetsBinding.instance.addPostFrameCallback((_){pick();});}
  @override void dispose(){a.cancel();b.cancel();c.cancel();widget.bt.dispose();super.dispose();}
  Future<void> pick() async { await showDialog(context:context,builder:(_)=>DevicePicker(bt:widget.bt)); }
  Future<void> move(int x) async { try{await widget.bt.send('JEDZ:$x');}catch(e){snack('$e');} }
  Future<void> home() async {try{await widget.bt.send('HOME');}catch(e){snack('$e');}}
  void snack(String s)=>ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s)));
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Tarczociąg'),actions:[IconButton(icon:Icon(connected?Icons.bluetooth_connected:Icons.bluetooth_disabled,color:connected?Colors.green:Colors.red),onPressed:pick),IconButton(icon:const Icon(Icons.settings),onPressed:()async{await Navigator.push(context,MaterialPageRoute(builder:(_)=>Settings(store:widget.store,bt:widget.bt)));setState(()=>d=widget.store.distances);})]),body:SafeArea(child:Padding(padding:const EdgeInsets.all(16),child:Column(children:[Card(child:Padding(padding:const EdgeInsets.all(18),child:Column(children:[const Text('AKTUALNA POZYCJA'),Text('${pos.toStringAsFixed(1)} m',style:const TextStyle(fontSize:52,fontWeight:FontWeight.w900)),Text(connected?'Połączono':'Brak połączenia'),]))),const SizedBox(height:12),Expanded(child:GridView.count(crossAxisCount:2,crossAxisSpacing:12,mainAxisSpacing:12,children:[for(final x in d)Card(child:InkWell(onTap:()=>move(x),child:Center(child:Column(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.linear_scale,size:34),Text('$x m',style:const TextStyle(fontSize:28,fontWeight:FontWeight.bold)),const Text('JEDŹ')]))))])),Card(child:ListTile(leading:const Icon(Icons.info_outline),title:const Text('Ostatni status'),subtitle:Text(stat))),const SizedBox(height:10),SizedBox(width:double.infinity,height:64,child:FilledButton.icon(onPressed:home,icon:const Icon(Icons.home,size:30),label:const Text('POWRÓT (HOME)',style:TextStyle(fontSize:20,fontWeight:FontWeight.w900))))]))));
}

class DevicePicker extends StatefulWidget { const DevicePicker({super.key,required this.bt}); final BtService bt; @override State<DevicePicker> createState()=>_DevicePickerState(); }
class _DevicePickerState extends State<DevicePicker>{List<BluetoothDevice> devices=[];bool loading=true; @override void initState(){super.initState();load();} Future<void> load()async{try{devices=await widget.bt.bonded();devices.sort((a,b)=>(a.name==targetName?0:1).compareTo(b.name==targetName?0:1));}finally{if(mounted)setState(()=>loading=false);}} @override Widget build(BuildContext c)=>AlertDialog(title:const Text('Wybierz urządzenie'),content:SizedBox(width:double.maxFinite,child:loading?const Center(child:CircularProgressIndicator()):devices.isEmpty?const Text('Brak sparowanych urządzeń. Sparuj Tarczociag_Puszka_BT w Androidzie.'):ListView(shrinkWrap:true,children:[for(final d in devices)ListTile(leading:const Icon(Icons.bluetooth),title:Text(d.name??'Bez nazwy'),subtitle:Text(d.address),trailing:d.name==targetName?const Chip(label:Text('TARCZA')):null,onTap:()async{Navigator.pop(c);try{await widget.bt.connect(d);}catch(e){if(mounted)ScaffoldMessenger.of(c).showSnackBar(SnackBar(content:Text('Błąd: $e')));}})])),actions:[TextButton(onPressed:load,child:const Text('ODŚWIEŻ')),TextButton(onPressed:()=>Navigator.pop(c),child:const Text('ANULUJ'))]);}

class Settings extends StatefulWidget { const Settings({super.key,required this.store,required this.bt}); final SettingsStore store; final BtService bt; @override State<Settings> createState()=>_SettingsState(); }
class _SettingsState extends State<Settings>{late List<TextEditingController> dc;late TextEditingController speed,ramp; @override void initState(){super.initState();dc=widget.store.distances.map((x)=>TextEditingController(text:'$x')).toList();speed=TextEditingController(text:'${widget.store.speed}');ramp=TextEditingController(text:'${widget.store.ramp}');} @override void dispose(){for(final x in dc)x.dispose();speed.dispose();ramp.dispose();super.dispose();} void msg(String s)=>ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s))); Future<void> saveD()async{final v=dc.map((x)=>int.tryParse(x.text.trim())).toList();if(v.any((x)=>x==null||x!<=0)){msg('Dystanse muszą być dodatnimi liczbami.');return;}final a=v.cast<int>();await widget.store.saveDistances(a);try{await widget.bt.send('SET_DIST:${a[0]},${a[1]},${a[2]},${a[3]}');msg('Dystanse wysłane.');}catch(e){msg('Zapisano lokalnie: $e');}} Future<void> saveM()async{final s=int.tryParse(speed.text),r=int.tryParse(ramp.text);if(s==null||s<50||s>255){msg('PWM: 50–255.');return;}if(r==null||r<0){msg('Rampa musi być >= 0.');return;}await widget.store.saveMotor(s,r);try{await widget.bt.send('SET_MOTOR:$s,$r');msg('Parametry silnika wysłane.');}catch(e){msg('Zapisano lokalnie: $e');}} @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Ustawienia')),body:ListView(padding:const EdgeInsets.all(16),children:[Card(child:Padding(padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Dystanse',style:TextStyle(fontSize:22,fontWeight:FontWeight.bold)),for(var i=0;i<4;i++)Padding(padding:const EdgeInsets.only(top:12),child:TextField(controller:dc[i],keyboardType:TextInputType.number,decoration:InputDecoration(labelText:'Preset ${i+1}',suffixText:'m'))),const SizedBox(height:16),SizedBox(width:double.infinity,child:FilledButton(onPressed:saveD,child:const Text('ZAPISZ DYSTANSE')))]))),Card(child:Padding(padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Silnik',style:TextStyle(fontSize:22,fontWeight:FontWeight.bold)),TextField(controller:speed,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Maksymalna prędkość PWM',helperText:'50–255')),const SizedBox(height:12),TextField(controller:ramp,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Rampa przyspieszania/hamowania',suffixText:'impulsów')),const SizedBox(height:16),SizedBox(width:double.infinity,child:FilledButton(onPressed:saveM,child:const Text('ZAPISZ PARAMETRY SILNIKA')))])))]));}
