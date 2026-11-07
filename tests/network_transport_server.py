"""Local transport fixture: deterministic TLS, headers, redirect and >8 MB body."""
import http.server,json,ssl,sys,io,wave,threading
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args): pass
    def handle(self):
        try: super().handle()
        except (BrokenPipeError,ConnectionResetError,ssl.SSLError): pass
    def do_GET(self):
        if self.path=='/redirect':
            self.send_response(302);self.send_header('Location','https://localhost:%d/headers'%self.server.server_port);self.send_header('Content-Length','0');self.end_headers();return
        if self.path in ('/audio-redirect','/http-redirect'):
            scheme='http' if self.path=='/http-redirect' or not self.server.is_tls else 'https'
            port=self.server.http_port if scheme=='http' else self.server.server_port
            self.send_response(302);self.send_header('Location',scheme+'://localhost:%d/audio'%port);self.send_header('Content-Length','0');self.end_headers();return
        if self.path=='/status403':
            self.send_response(403);self.send_header('Content-Length','0');self.end_headers();return
        if self.path=='/audio':
            out=io.BytesIO()
            with wave.open(out,'wb') as audio:
                audio.setnchannels(1);audio.setsampwidth(2);audio.setframerate(8000);audio.writeframes(b'\0'*1600)
            data=out.getvalue()
        else:
            data=json.dumps(dict(self.headers)).encode() if self.path=='/headers' else b'x'*9*1024*1024
        self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers()
        try:
            for start in range(0,len(data),16384): self.wfile.write(data[start:start+16384])
        except (BrokenPipeError,ConnectionResetError,ssl.SSLError): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
plain=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
plain.is_tls=False;plain.http_port=plain.server_port
server.is_tls=True;server.http_port=plain.server_port
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(sys.argv[1],sys.argv[2]);server.socket=context.wrap_socket(server.socket,server_side=True)
threading.Thread(target=plain.serve_forever,daemon=True).start()
open(sys.argv[3]+'.http','w').write(str(plain.server_port))
open(sys.argv[3],'w').write(str(server.server_port))
server.serve_forever()
