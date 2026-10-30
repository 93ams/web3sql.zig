-- web3sql Snowflake UDFs. Generated from the function catalogue; do not edit.
-- UNVERIFIED on a live account: Snowflake does not document WebAssembly in JavaScript UDFs,
-- and recommends bodies under 100 KB. Run one CREATE and one SELECT before deploying all.
CREATE OR REPLACE FUNCTION web3_flag(A0 VARCHAR) RETURNS BOOLEAN LANGUAGE JAVASCRIPT RETURNS NULL ON NULL INPUT AS $$
var WEB3_WASM="QUJD";
var W3B="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
function w3Unb64(s){var n=s.length;while(n>0&&s.charAt(n-1)=="=")n--;var o=new Uint8Array(Math.floor(n*3/4)),b=0,c=0,p=0;for(var i=0;i<n;i++){b=(b<<6)|W3B.indexOf(s.charAt(i));c+=6;if(c>=8){c-=8;o[p++]=(b>>c)&255;b&=(1<<c)-1;}}return o;}
function w3B64(u){var s="",i=0;for(;i+2<u.length;i+=3){var v=(u[i]<<16)|(u[i+1]<<8)|u[i+2];s+=W3B.charAt(v>>18)+W3B.charAt((v>>12)&63)+W3B.charAt((v>>6)&63)+W3B.charAt(v&63);}if(i+1==u.length){var a=u[i]<<16;s+=W3B.charAt(a>>18)+W3B.charAt((a>>12)&63)+"==";}else if(i+2==u.length){var d=(u[i]<<16)|(u[i+1]<<8);s+=W3B.charAt(d>>18)+W3B.charAt((d>>12)&63)+W3B.charAt((d>>6)&63)+"=";}return s;}
function w3Utf8(s){var e=unescape(encodeURIComponent(s)),u=new Uint8Array(e.length);for(var i=0;i<e.length;i++)u[i]=e.charCodeAt(i);return u;}
function w3Text(u){var s="";for(var i=0;i<u.length;i++)s+=String.fromCharCode(u[i]);return decodeURIComponent(escape(s));}
function web3_call(name,args,kinds,ret){
var g=typeof globalThis!="undefined"?globalThis:this;
if(!g.__web3)g.__web3=new WebAssembly.Instance(new WebAssembly.Module(w3Unb64(WEB3_WASM)),{}).exports;
var w=g.__web3,n=args.length;
for(var i=0;i<n;i++)if(args[i]===null||args[i]===undefined)return null;
w.web3_free();
var argv=w.web3_alloc(8*n);if(!argv&&n)return null;
for(var i=0;i<n;i++){var v=args[i],k=kinds.charAt(i),lo,hi;
if(k=="i"){var x=Number(v);if(!Number.isSafeInteger(x))return null;lo=x>>>0;hi=Math.floor(x/4294967296)>>>0;}
else{var u=k=="t"?w3Utf8(String(v)):(typeof v=="string"?w3Unb64(v):v);lo=u.length?w.web3_alloc(u.length):0;if(u.length&&!lo)return null;hi=u.length;new Uint8Array(w.memory.buffer,lo,u.length).set(u);}
var dv=new DataView(w.memory.buffer);dv.setUint32(argv+8*i,lo,true);dv.setUint32(argv+8*i+4,hi,true);}
var cap=w.web3_available(),out=w.web3_alloc(cap),len=w[name](argv,n,out,cap);
if(len<0)return null;
var r=new Uint8Array(w.memory.buffer,out,len);
if(ret=="o")return r[0]!=0;
if(ret=="i")return Number(new DataView(w.memory.buffer).getBigInt64(out,true));
if(ret=="t")return w3Text(r);
return new Uint8Array(r);}
return web3_call("web3_flag",[A0],"t","o");
$$;
