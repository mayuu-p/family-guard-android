import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:http/http.dart' as http;

const apiBase = String.fromEnvironment('API_BASE_URL', defaultValue: 'https://ewvirpfovwruxshzzlaa.supabase.co/functions/v1/family-api');
const supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImV3dmlycGZvdndydXhzaHp6bGFhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM1OTEwMzUsImV4cCI6MjA4OTE2NzAzNX0.G6Nu1pE7Z2P_M2hEknVJWU5hvjwvSuT_StX2ZKSq3bY';
const storage = FlutterSecureStorage();

void main() => runApp(const FamilySafetyApp());

class Api {
  Future<String?> get token => storage.read(key: 'jwt');
  Future<Map<String, dynamic>> request(String path, {String method='GET', Map<String,dynamic>? body}) async {
    final t = await token;
    final headers = {'Content-Type':'application/json', 'apikey':supabaseAnonKey, if (t != null) 'Authorization':'Bearer $t'};
    final uri = Uri.parse('$apiBase$path');
    late http.Response response;
    if (method == 'POST') {
      response = await http.post(uri, headers: headers, body: jsonEncode(body ?? {}));
    } else if (method == 'DELETE') {
      response = await http.delete(uri, headers: headers);
    } else {
      response = await http.get(uri, headers: headers);
    }
    final data = response.body.isEmpty ? <String,dynamic>{} : (jsonDecode(response.body) as Map<String,dynamic>);
    if (response.statusCode < 200 || response.statusCode >= 300) throw Exception(data['error'] ?? 'Request failed (${response.statusCode})');
    return data;
  }
}

class FamilySafetyApp extends StatelessWidget {
  const FamilySafetyApp({super.key});
  @override Widget build(BuildContext context) => MaterialApp(title:'Family Safety',debugShowCheckedModeBanner:false,
    theme:ThemeData(colorSchemeSeed:const Color(0xff2563eb),useMaterial3:true),home:const Gate());
}
class Gate extends StatefulWidget { const Gate({super.key}); @override State<Gate> createState()=>_GateState(); }
class _GateState extends State<Gate> {
  String? role;
  @override void initState(){super.initState();_load();}
  Future<void> _load() async { final r=await storage.read(key:'role'); if(mounted)setState(()=>role=r); }
  @override Widget build(BuildContext context){if(role==null)return LoginScreen(onLogin:(r)=>setState(()=>role=r));return role=='child'?const ChildScreen():const ParentScreen();}
}
class LoginScreen extends StatefulWidget {
  final ValueChanged<String> onLogin; const LoginScreen({super.key,required this.onLogin});
  @override State<LoginScreen> createState()=>_LoginScreenState();
}
class _LoginScreenState extends State<LoginScreen>{
  final email=TextEditingController(),password=TextEditingController(),name=TextEditingController();
  String role='parent';bool register=false,busy=false;String? error;
  Future<void> submit() async {
    setState(() { busy=true; error=null; });
    try{
      final result=await Api().request(register?'/api/auth/register':'/api/auth/login',method:'POST',body:register
        ?{'email':email.text.trim(),'password':password.text,'displayName':name.text.trim(),'role':role}
        :{'email':email.text.trim(),'password':password.text});
      if(register){if(!mounted)return;ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Account created. Sign in now.')));setState(()=>register=false);}
      else{await storage.write(key:'jwt',value:result['token']);await storage.write(key:'role',value:result['user']['role']);widget.onLogin(result['user']['role']);}
    }catch(e){setState(()=>error=e.toString().replaceFirst('Exception: ',''));}
    finally{if(mounted)setState(()=>busy=false);}
  }
  @override Widget build(BuildContext context)=>Scaffold(body:Center(child:SingleChildScrollView(padding:const EdgeInsets.all(24),child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:420),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
    const Icon(Icons.family_restroom,size:64,color:Colors.blue),const SizedBox(height:12),Text('Family Safety',style:Theme.of(context).textTheme.headlineMedium,textAlign:TextAlign.center),const SizedBox(height:24),
    if(register)TextField(controller:name,decoration:const InputDecoration(labelText:'Display name')),
    TextField(controller:email,decoration:const InputDecoration(labelText:'Email'),keyboardType:TextInputType.emailAddress),
    TextField(controller:password,decoration:const InputDecoration(labelText:'Password (10+ characters)'),obscureText:true),
    if(register)DropdownButtonFormField<String>(value:role,decoration:const InputDecoration(labelText:'Account type'),items:const [DropdownMenuItem(value:'parent',child:Text('Parent')),DropdownMenuItem(value:'child',child:Text('Child'))],onChanged:(v)=>setState(()=>role=v??'parent')),
    if(error!=null)Padding(padding:const EdgeInsets.only(top:12),child:Text(error!,style:const TextStyle(color:Colors.red))),
    const SizedBox(height:16),FilledButton(onPressed:busy?null:submit,child:Text(busy?'Please wait':register?'Create account':'Sign in')),
    TextButton(onPressed:()=>setState(()=>register=!register),child:Text(register?'Already have an account? Sign in':'Create an account')),
  ])))));
}

class ChildScreen extends StatefulWidget{const ChildScreen({super.key});@override State<ChildScreen> createState()=>_ChildScreenState();}
class _ChildScreenState extends State<ChildScreen>{
  bool sharing=false,busy=false;Timer? timer;String status='Location sharing is off';final code=TextEditingController();
  Future<void> refreshStatus()async{try{final r=await Api().request('/api/family/status');if(mounted)setState(()=>sharing=r['sharingEnabled']==true);}catch(e){if(mounted)setState(()=>status='$e');}}
  Future<void> pair()async{try{await Api().request('/api/family/redeem-code',method:'POST',body:{'code':code.text.trim()});await refreshStatus();if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Family pairing successful')));}catch(e){setState(()=>status='$e');}}
  Future<void> setSharing(bool enabled)async{
    if(enabled){final service=await Geolocator.isLocationServiceEnabled();if(!service){setState(()=>status='Turn on device location first');return;}var p=await Geolocator.checkPermission();if(p==LocationPermission.denied)p=await Geolocator.requestPermission();if(p==LocationPermission.denied||p==LocationPermission.deniedForever){setState(()=>status='Location permission is required to share');return;}}
    try{await Api().request('/api/sharing/consent',method:'POST',body:{'enabled':enabled});setState(()=>sharing=enabled);timer?.cancel();if(enabled){await sendLocation();timer=Timer.periodic(const Duration(seconds:30),(_)=>sendLocation());setState(()=>status='Location sharing is active while this app is running');}else{setState(()=>status='Location sharing is paused');}}catch(e){setState(()=>status='$e');}
  }
  Future<void> sendLocation()async{if(!sharing)return;try{final p=await Geolocator.getCurrentPosition(locationSettings:const LocationSettings(accuracy:LocationAccuracy.high,timeLimit:Duration(seconds:15)));final battery=await Battery().batteryLevel;await Api().request('/api/location',method:'POST',body:{'latitude':p.latitude,'longitude':p.longitude,'accuracyM':p.accuracy,'batteryLevel':battery,'recordedAt':DateTime.now().toUtc().toIso8601String()});if(mounted)setState(()=>status='Last shared: ${DateTime.now().toLocal()}');}catch(e){if(mounted)setState(()=>status='Location update failed: $e');}}
  Future<void> sos()async{setState(()=>busy=true);try{Position? p;try{p=await Geolocator.getCurrentPosition(locationSettings:const LocationSettings(timeLimit:Duration(seconds:8)));}catch(_){}await Api().request('/api/sos',method:'POST',body:{if(p!=null)'latitude':p.latitude,if(p!=null)'longitude':p.longitude,'message':'SOS emergency — please contact me'});if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('SOS saved for your linked parent')));}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('SOS failed: $e')));}finally{if(mounted)setState(()=>busy=false);}}
  Future<void> checkIn()async{try{await Api().request('/api/check-ins',method:'POST',body:{'message':'Reached safely'});if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Safe check-in sent')));}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}}
  @override void initState(){super.initState();refreshStatus();}
  @override void dispose(){timer?.cancel();code.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Child Safety Mode'),actions:[IconButton(onPressed:()async{timer?.cancel();await storage.deleteAll();if(mounted)Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder:(_)=>const Gate()),(_)=>false);},icon:const Icon(Icons.logout))]),body:ListView(padding:const EdgeInsets.all(20),children:[
    Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Your location sharing',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),const SizedBox(height:8),Text(status),SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('Share my location with Parent'),subtitle:const Text('You can turn this off at any time.'),value:sharing,onChanged:setSharing)]))),
    const SizedBox(height:12),TextField(controller:code,decoration:const InputDecoration(labelText:'Parent pairing code',border:OutlineInputBorder())),const SizedBox(height:8),OutlinedButton(onPressed:pair,child:const Text('Link with parent')),const SizedBox(height:24),
    SizedBox(height:58,child:FilledButton.icon(style:FilledButton.styleFrom(backgroundColor:Colors.red),onPressed:busy?null:sos,icon:const Icon(Icons.sos),label:const Text('SOS EMERGENCY'))),
    const SizedBox(height:12),OutlinedButton.icon(onPressed:checkIn,icon:const Icon(Icons.check_circle),label:const Text('Reached safely — Check in')),
    const SizedBox(height:16),const Text('Location sharing starts only after you enable it. This version does not hide tracking or enable background sharing.')
  ]));}
class ParentScreen extends StatefulWidget{const ParentScreen({super.key});@override State<ParentScreen> createState()=>_ParentScreenState();}
class _ParentScreenState extends State<ParentScreen>{
  Timer? timer;
  double? latitude,longitude;
  String status='Loading family status...';
  final name=TextEditingController();
  final radius=TextEditingController(text:'150');
  bool loading=false;
  @override void initState(){super.initState();load();timer=Timer.periodic(const Duration(seconds:20),(_)=>load());}
  Future<void> load() async {
    if(loading)return;
    loading=true;
    try {
      final s=await Api().request('/api/family/status');
      if(!mounted)return;
      if(s['linked']!=true){setState(()=>status='No child linked. Generate a pairing code and link the child device.');return;}
      final childInfo=s['child'];
      if(childInfo is! Map || childInfo['sharingEnabled']!=true){setState(()=>status='Your child has paused location sharing.');return;}
      final r=await Api().request('/api/family/child/location');
      final loc=r['location'];
      if(loc==null){setState(()=>status='Waiting for the child’s first location update.');return;}
      setState(() {
        latitude=(loc['latitude'] as num).toDouble();
        longitude=(loc['longitude'] as num).toDouble();
        status='Last updated: ${loc['recorded_at']}';
      });
    } catch(e) {
      if(mounted)setState(()=>status=e.toString().replaceFirst('Exception: ',''));
    } finally { loading=false; }
  }
  Future<void> createCode()async{
    try{
      final r=await Api().request('/api/family/pairing-code',method:'POST');
      if(!mounted)return;
      showDialog(context:context,builder:(_)=>AlertDialog(
        title:const Text('Parent pairing code'),
        content:SelectableText('${r['code']}\\nExpires in 15 minutes. Share privately with the child.'),
        actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('Close'))]));
    }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}
  }
  Future<void> addFence()async{
    if(latitude==null||longitude==null){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('A child location is not available yet.')));return;}
    try{
      await Api().request('/api/geofences',method:'POST',body:{
        'name':name.text.trim().isEmpty?'Safe Zone':name.text.trim(),
        'latitude':latitude,'longitude':longitude,'radiusM':int.tryParse(radius.text)??150});
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Safe zone saved.')));
    }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}
  }
  @override void dispose(){timer?.cancel();name.dispose();radius.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:const Text('Parent Dashboard'),actions:[
      IconButton(onPressed:()async{timer?.cancel();await storage.deleteAll();if(mounted)Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder:(_)=>const Gate()),(_)=>false);},icon:const Icon(Icons.logout))
    ]),
    body:ListView(padding:const EdgeInsets.all(16),children:[
      Card(child:Padding(padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        const Row(children:[Icon(Icons.location_on,color:Colors.blue),SizedBox(width:8),Text('Child location',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold))]),
        const SizedBox(height:12),
        Text(status),
        if(latitude!=null&&longitude!=null) ...[
          const SizedBox(height:12),
          SelectableText('Latitude: ${latitude!.toStringAsFixed(6)}\\nLongitude: ${longitude!.toStringAsFixed(6)}'),
          const SizedBox(height:6),
          const Text('Location updates refresh every 20 seconds while the dashboard is open.',style:TextStyle(color:Colors.grey))
        ],
        const SizedBox(height:12),
        Row(children:[
          Expanded(child:OutlinedButton.icon(onPressed:createCode,icon:const Icon(Icons.link),label:const Text('Pair child'))),
          const SizedBox(width:8),
          Expanded(child:OutlinedButton.icon(onPressed:load,icon:const Icon(Icons.refresh),label:const Text('Refresh')))
        ])
      ]))),
      const SizedBox(height:12),
      Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        const Text('Safe zone',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
        const SizedBox(height:8),
        const Text('Create a safe zone around the child’s latest shared location.'),
        TextField(controller:name,decoration:const InputDecoration(labelText:'Zone name')),
        TextField(controller:radius,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Radius in metres (50–10000)')),
        const SizedBox(height:8),
        FilledButton(onPressed:addFence,child:const Text('Create safe zone'))
      ])))
    ])
  );
}

