#!/bin/bash
set -euo pipefail
git clone --depth 1 https://github.com/jasonxu114514/opencode2api.git upstream
git -C upstream rev-parse HEAD > upstream-commit.txt
mkdir -p app/src/main/jniLibs/arm64-v8a app/src/main/java/dev/catsuki/opencode2api app/src/main/assets
export CC="$ANDROID_HOME/ndk/26.3.11579264/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
(cd upstream; CGO_ENABLED=1 GOOS=android GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o ../app/src/main/jniLibs/arm64-v8a/libopencode2api.so ./cmd/opencode2api)
file app/src/main/jniLibs/arm64-v8a/libopencode2api.so
cp upstream/config.example.json app/src/main/assets/config.example.json
cat > settings.gradle <<'EOF'
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS); repositories { google(); mavenCentral() } }
rootProject.name = 'OpenCode2APIAndroid'
include ':app'
EOF
cat > build.gradle <<'EOF'
plugins { id 'com.android.application' version '8.7.3' apply false }
EOF
cat > gradle.properties <<'EOF'
org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8
android.useAndroidX=true
EOF
cat > app/build.gradle <<'EOF'
plugins { id 'com.android.application' }
android {
 namespace 'dev.catsuki.opencode2api'
 compileSdk 35
 defaultConfig {
  applicationId 'dev.catsuki.opencode2api'
  minSdk 26
  targetSdk 33
  versionCode 1
  versionName '1.0.0'
  ndk { abiFilters 'arm64-v8a' }
 }
 compileOptions { sourceCompatibility JavaVersion.VERSION_17; targetCompatibility JavaVersion.VERSION_17 }
 packaging { jniLibs { useLegacyPackaging = true } }
}
EOF
cat > app/src/main/AndroidManifest.xml <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
 <uses-permission android:name="android.permission.INTERNET"/>
 <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
 <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
 <application android:label="OpenCode2API" android:theme="@android:style/Theme.Material.Light.NoActionBar" android:usesCleartextTraffic="true" android:extractNativeLibs="true" android:allowBackup="false">
  <activity android:name=".MainActivity" android:exported="true">
   <intent-filter><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent-filter>
  </activity>
  <service android:name=".GatewayService" android:exported="false"/>
 </application>
</manifest>
EOF
cat > app/src/main/java/dev/catsuki/opencode2api/GatewayService.java <<'EOF'
package dev.catsuki.opencode2api;
import android.app.*;
import android.content.*;
import android.os.*;
import android.util.Log;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import android.util.Base64;

public final class GatewayService extends Service {
 static final String URL = "http://127.0.0.1:8081";
 private volatile Process process;
 static void send(Context c, boolean stop) {
  Intent i=new Intent(c,GatewayService.class).setAction(stop?"stop":"start");
  if(stop) c.startService(i); else c.startForegroundService(i);
 }
 @Override public void onCreate(){
  super.onCreate();
  ((NotificationManager)getSystemService(NOTIFICATION_SERVICE)).createNotificationChannel(new NotificationChannel("gateway","OpenCode2API 网关",NotificationManager.IMPORTANCE_LOW));
 }
 @Override public int onStartCommand(Intent i,int flags,int startId){
  if(i!=null && "stop".equals(i.getAction())){
   if(process!=null)process.destroy();
   process=null; stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(); return START_NOT_STICKY;
  }
  PendingIntent pi=PendingIntent.getActivity(this,0,new Intent(this,MainActivity.class),PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_UPDATE_CURRENT);
  startForeground(7,new Notification.Builder(this,"gateway").setSmallIcon(android.R.drawable.stat_sys_upload).setContentTitle("OpenCode2API 正在运行").setContentText("API 8080 · 管理 8081").setContentIntent(pi).build());
  if(process==null || !process.isAlive())new Thread(this::launch,"gateway-launch").start();
  return START_STICKY;
 }
 static File dir(Context c){File d=new File(c.getFilesDir(),"gateway");d.mkdirs();return d;}
 static File config(Context c){return new File(dir(c),"config.json");}
 static String token(){byte[] b=new byte[24];new SecureRandom().nextBytes(b);return Base64.encodeToString(b,Base64.URL_SAFE|Base64.NO_WRAP|Base64.NO_PADDING);}
 static synchronized void ensureConfig(Context c)throws Exception{
  if(config(c).exists())return;
  ByteArrayOutputStream out=new ByteArrayOutputStream();
  try(InputStream in=c.getAssets().open("config.example.json")){byte[] b=new byte[4096];int n;while((n=in.read(b))!=-1)out.write(b,0,n);}
  JSONObject cfg=new JSONObject(out.toString("UTF-8"));
  String api=token(),pass=token();
  cfg.put("listen","127.0.0.1:8080");cfg.put("server_keys",new JSONArray().put(api));cfg.put("zen_keys",new JSONArray());cfg.put("go_keys",new JSONArray());cfg.put("anonymous",true);
  JSONObject ui=cfg.getJSONObject("webui");ui.put("enabled",true);ui.put("listen","127.0.0.1:8081");ui.put("username","admin");ui.put("password",pass);
  try(FileOutputStream f=new FileOutputStream(config(c))){f.write(cfg.toString(2).getBytes(StandardCharsets.UTF_8));f.getFD().sync();}
  c.getSharedPreferences("creds",0).edit().putString("api",api).putString("pass",pass).apply();
 }
 static String credentials(Context c){
  android.content.SharedPreferences s=c.getSharedPreferences("creds",0);
  return "管理地址：http://127.0.0.1:8081\n用户名：admin\n初始管理密码："+s.getString("pass","请查看配置")+"\n\nAPI：http://127.0.0.1:8080/v1\nAPI Key："+s.getString("api","请查看配置");
 }
 private void log(String s){
  Log.i("OpenCode2API",s);
  try(FileOutputStream f=new FileOutputStream(new File(dir(this),"gateway.log"),true)){f.write((s+"\n").getBytes(StandardCharsets.UTF_8));}catch(Exception ignored){}
 }
 private void launch(){
  try{
   ensureConfig(this);
   File exe=new File(getApplicationInfo().nativeLibraryDir,"libopencode2api.so");
   ProcessBuilder pb=new ProcessBuilder(exe.getAbsolutePath(),"-config",config(this).getAbsolutePath());
   pb.directory(dir(this)).redirectErrorStream(true);
   pb.environment().put("HOME",dir(this).getAbsolutePath());
   pb.environment().put("TMPDIR",getCacheDir().getAbsolutePath());
   Process child=pb.start();process=child;
   try(BufferedReader br=new BufferedReader(new InputStreamReader(child.getInputStream(),StandardCharsets.UTF_8))){String line;while((line=br.readLine())!=null)log(line);}
   log("exit code "+child.waitFor());
  }catch(Exception e){log("启动失败："+Log.getStackTraceString(e));}
 }
 @Override public void onDestroy(){if(process!=null)process.destroy();super.onDestroy();}
 @Override public IBinder onBind(Intent i){return null;}
}
EOF
cat > app/src/main/java/dev/catsuki/opencode2api/MainActivity.java <<'EOF'
package dev.catsuki.opencode2api;
import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.os.*;
import android.view.*;
import android.webkit.*;
import android.widget.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;

public final class MainActivity extends Activity {
 private TextView status;
 private WebView web;
 private Handler handler=new Handler(Looper.getMainLooper());
 private final Runnable poll=new Runnable(){
  public void run(){
   if(status!=null){
    new Thread(()->{boolean ok=false;try(Socket s=new Socket()){s.connect(new InetSocketAddress("127.0.0.1",8081),400);ok=true;}catch(Exception ignored){}boolean result=ok;runOnUiThread(()->{if(status!=null)status.setText(result?"● 服务运行中":"○ 服务尚未就绪");});}).start();
    handler.postDelayed(this,2500);
   }
  }
 };
 @Override public void onCreate(Bundle b){
  super.onCreate(b);showHome();
  if(Build.VERSION.SDK_INT>=33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED)requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS},10);
  startGateway();
 }
 private void startGateway(){
  try{GatewayService.ensureConfig(this);GatewayService.send(this,false);}
  catch(Exception e){Toast.makeText(this,"启动失败："+e,Toast.LENGTH_LONG).show();}
 }
 private int dp(int n){return (int)(n*getResources().getDisplayMetrics().density+.5);}
 private void showHome(){
  if(web!=null){web.destroy();web=null;}
  ScrollView scroll=new ScrollView(this);scroll.setBackgroundColor(0xFFF7F8FA);
  LinearLayout root=new LinearLayout(this);root.setOrientation(1);root.setPadding(dp(20),dp(30),dp(20),dp(20));scroll.addView(root);
  TextView title=new TextView(this);title.setText("OpenCode2API");title.setTextSize(26);title.setTextColor(0xFF172334);root.addView(title);
  status=new TextView(this);status.setText("正在检查…");status.setTextSize(17);status.setPadding(0,dp(25),0,dp(15));root.addView(status);
  add(root,"打开管理后台",()->{
   status=null;handler.removeCallbacks(poll);web=new WebView(this);web.getSettings().setJavaScriptEnabled(true);web.getSettings().setDomStorageEnabled(true);web.setWebViewClient(new WebViewClient());setContentView(web);web.loadUrl(GatewayService.URL);
  });
  add(root,"启动服务",this::startGateway);
  add(root,"停止服务",()->GatewayService.send(this,true));
  add(root,"查看 / 复制初始登录信息",()->{
   String creds=GatewayService.credentials(this);
   new AlertDialog.Builder(this).setTitle("管理信息").setMessage(creds).setPositiveButton("复制",(d,w)->{((android.content.ClipboardManager)getSystemService(CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newPlainText("OpenCode2API",creds));Toast.makeText(this,"已复制",Toast.LENGTH_SHORT).show();}).setNegativeButton("关闭",null).show();
  });
  add(root,"查看日志",()->{
   String s="暂无日志";
   try{File f=new File(GatewayService.dir(this),"gateway.log");if(f.exists()){s=new String(java.nio.file.Files.readAllBytes(f.toPath()),StandardCharsets.UTF_8);if(s.length()>12000)s=s.substring(s.length()-12000);}}catch(Exception e){s=e.toString();}
   new AlertDialog.Builder(this).setTitle("最近日志").setMessage(s).setPositiveButton("关闭",null).show();
  });
  TextView footer=new TextView(this);footer.setText("本机 API：http://127.0.0.1:8080/v1\n首次启动使用匿名上游，密钥可在管理后台添加。");footer.setPadding(0,dp(20),0,0);root.addView(footer);
  setContentView(scroll);handler.post(poll);
 }
 private void add(LinearLayout root,String text,Runnable r){Button b=new Button(this);b.setText(text);b.setAllCaps(false);root.addView(b,new LinearLayout.LayoutParams(-1,dp(54)));b.setOnClickListener(v->r.run());}
 @Override public void onBackPressed(){if(web!=null){web.destroy();web=null;showHome();}else super.onBackPressed();}
 @Override public void onDestroy(){handler.removeCallbacks(poll);super.onDestroy();}
}
EOF
