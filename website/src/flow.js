/* ---------- Fireflies: the page's living background, drawn on the graphics card (WebGL2) ----------
   The Colorway's three soft light pools drift slowly behind the page, and soft lights rise through them:
   near ones big and blurred, far ones small and bright. Everything is computed on the graphics card; the
   CPU only hands over the time and the colours. The dark page stays true black wherever nothing is lit,
   which suits OLED screens. Without WebGL2 the canvas keeps the still CSS glow it is styled with. */
(() => {
  const c = document.getElementById('flow'); if (!c) return;
  const root = document.documentElement;
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const gl = c.getContext('webgl2', { alpha: true, premultipliedAlpha: true, antialias: false, powerPreference: 'low-power' });
  if (!gl) return;
  const light = () => window.VC?.isLight ? window.VC.isLight() : root.dataset.look === 'light' || (!root.dataset.look && matchMedia('(prefers-color-scheme: light)').matches);

  const NOISE = `vec3 m289(vec3 x){return x-floor(x*(1./289.))*289.;}vec4 m289(vec4 x){return x-floor(x*(1./289.))*289.;}
vec4 perm(vec4 x){return m289(((x*34.)+1.)*x);}vec4 tis(vec4 r){return 1.79284291400159-.85373472095314*r;}
float snoise(vec3 v){const vec2 C=vec2(1./6.,1./3.);const vec4 D=vec4(0.,.5,1.,2.);vec3 i=floor(v+dot(v,C.yyy));vec3 x0=v-i+dot(i,C.xxx);
vec3 g=step(x0.yzx,x0.xyz);vec3 l=1.-g;vec3 i1=min(g.xyz,l.zxy);vec3 i2=max(g.xyz,l.zxy);vec3 x1=x0-i1+C.xxx;vec3 x2=x0-i2+C.yyy;vec3 x3=x0-D.yyy;
i=m289(i);vec4 p=perm(perm(perm(i.z+vec4(0.,i1.z,i2.z,1.))+i.y+vec4(0.,i1.y,i2.y,1.))+i.x+vec4(0.,i1.x,i2.x,1.));
float n_=.142857142857;vec3 ns=n_*D.wyz-D.xzx;vec4 j=p-49.*floor(p*ns.z*ns.z);vec4 x_=floor(j*ns.z);vec4 y_=floor(j-7.*x_);
vec4 x=x_*ns.x+ns.yyyy;vec4 y=y_*ns.x+ns.yyyy;vec4 h=1.-abs(x)-abs(y);vec4 b0=vec4(x.xy,y.xy);vec4 b1=vec4(x.zw,y.zw);
vec4 s0=floor(b0)*2.+1.;vec4 s1=floor(b1)*2.+1.;vec4 sh=-step(h,vec4(0.));vec4 a0=b0.xzyw+s0.xzyw*sh.xxyy;vec4 a1=b1.xzyw+s1.xzyw*sh.zzww;
vec3 p0=vec3(a0.xy,h.x);vec3 p1=vec3(a0.zw,h.y);vec3 p2=vec3(a1.xy,h.z);vec3 p3=vec3(a1.zw,h.w);
vec4 nm=tis(vec4(dot(p0,p0),dot(p1,p1),dot(p2,p2),dot(p3,p3)));p0*=nm.x;p1*=nm.y;p2*=nm.z;p3*=nm.w;
vec4 m=max(.6-vec4(dot(x0,x0),dot(x1,x1),dot(x2,x2),dot(x3,x3)),0.);m=m*m;return 42.*dot(m*m,vec4(dot(p0,x0),dot(p1,x1),dot(p2,x2),dot(p3,x3)));}`;
  function prog(vs, fs) {
    const mk = (t, s) => { const o = gl.createShader(t); gl.shaderSource(o, '#version 300 es\nprecision highp float;\n' + s); gl.compileShader(o); if (!gl.getShaderParameter(o, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(o)); return o; };
    const p = gl.createProgram(); gl.attachShader(p, mk(gl.VERTEX_SHADER, vs)); gl.attachShader(p, mk(gl.FRAGMENT_SHADER, fs)); gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
    const u = {}; const n = gl.getProgramParameter(p, gl.ACTIVE_UNIFORMS); for (let i = 0; i < n; i++) { const a = gl.getActiveUniform(p, i); u[a.name] = gl.getUniformLocation(p, a.name); }
    return { p, u };
  }
  let poolP, flyP;
  try {
    // the glow: the same three pools as the still page (same spots, sizes and strength), drifting and slowly bleeding into each other
    poolP = prog(`out vec2 vU;void main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);vU=p;gl_Position=vec4(p*2.-1.,0.,1.);}`,
      `${NOISE}uniform vec3 uG0,uG1,uG2;uniform vec2 uR;uniform float uT;uniform float uL;in vec2 vU;out vec4 o;
      float pool(vec2 q,vec2 c,vec2 r){return 1.-smoothstep(0.,.7,length((q-c)/r));}
      vec4 over(vec3 c,float a,vec4 d){return vec4(c*a,a)+d*(1.-a);}
      void main(){float m=max(uR.x,uR.y);vec2 q=vec2(vU.x,1.-vU.y)*uR/m;float z=uT*.000045;
        q+=vec2(snoise(vec3(q*1.4,z)),snoise(vec3(q*1.4+9.,z)))*.05;
        vec2 a=uR/m;
        vec2 c1=a*vec2(.08+.22*sin(z*2.1),.04+.18*sin(z*1.7+1.))+vec2(.06*sin(z*5.),0.);
        vec2 c2=a*vec2(.94-.24*sin(z*1.8+2.),.40+.22*sin(z*2.3));
        vec2 c3=a*vec2(.40+.28*sin(z*1.5+4.),1.02-.20*sin(z*2.0+3.));
        float g=uL>.5?.30:.22;vec4 col=vec4(0.);
        col=over(uG0,g*pool(q,c1,vec2(.42,.34)),col);
        col=over(uG1,g*.72*pool(q,c2,vec2(.46,.40)),col);
        col=over(uG2,g*pool(q,c3,vec2(.50,.40)),col);
        col.rgb+=step(.004,col.a)*(fract(sin(dot(gl_FragCoord.xy,vec2(12.9898,78.233)))*43758.5453)-.5)/255.;
        o=col;}`);
    // the fireflies: each one knows only its number; where it is, how big and how bright come from the time
    flyP = prog(`uniform vec3 uC0,uC1,uC2;uniform float uT;uniform float uD;out vec3 vC;out float vA;out float vB;
      vec3 ramp(float h){float t=fract(h)*3.;return t<1.?mix(uC0,uC1,t):t<2.?mix(uC1,uC2,t-1.):mix(uC2,uC0,t-2.);}
      float h(float n){return fract(sin(n)*43758.5453);}
      void main(){float i=float(gl_VertexID),t=uT*.001,b=pow(h(i*7.13),3.);
        float y=fract(h(i*1.71)+t*(.006+.012*h(i*3.1))*(1.+b));
        float x=h(i*2.37)+.035*sin(t*(.25+.4*h(i*5.3))+i)+.012*sin(t*1.1+i*2.);
        gl_Position=vec4(fract(x)*2.-1.,y*2.3-1.15,0.,1.);
        gl_PointSize=min((3.+34.*b)*uD,96.);vB=b;
        vA=(.3+.7*pow(.5+.5*sin(t*(.5+h(i*9.1))*1.7+i*4.),3.))*mix(.95,.28,b);vC=ramp(h(i*11.3));}`,
      `uniform float uL;in vec3 vC;in float vA;in float vB;out vec4 o;
      void main(){float r=length(gl_PointCoord-.5)*2.;float a=mix(exp(-r*r*5.),smoothstep(1.,.7,r)*.8,vB)*vA;
        o=uL>.5?vec4(vC*.56*a,a*.8):vec4(vC*a+vec3(a*a*.25),a);}`);
  } catch (e) { return; }
  c.style.background = 'none'; // the canvas paints the glow itself now
  const vao = gl.createVertexArray(); gl.bindVertexArray(vao);

  // colours: the pools take the Colorway's glow, the fireflies its three colours; both glide to a new Colorway
  const hex = h => { const n = parseInt(h.slice(1), 16); return [(n >> 16 & 255) / 255, (n >> 8 & 255) / 255, (n & 255) / 255]; };
  const want = () => { const w = window.VC?.way; if (!w) return null; return [...(w.glow || [w.c[0], w.c[2], w.c[1]]), ...w.c].map(hex); };
  let pal = want() || Array.from({ length: 6 }, () => [.7, .55, 1]);
  const ease = () => { const t = want(); if (t) pal = pal.map((c, i) => c.map((v, n) => v + (t[i][n] - v) * .06)); };

  let W = 0, H = 0, d = 1, clock = 0;
  function size() { d = Math.min(devicePixelRatio || 1, 1.5); W = c.width = Math.max(1, Math.round(innerWidth * d)); H = c.height = Math.max(1, Math.round(innerHeight * d)); }
  const U3 = (pr, n, v) => pr.u[n] && gl.uniform3f(pr.u[n], v[0], v[1], v[2]);
  function draw(dt) {
    clock += dt; ease(); const L = light() ? 1 : 0;
    gl.viewport(0, 0, W, H); gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT);
    gl.disable(gl.BLEND); gl.useProgram(poolP.p);
    ['uG0', 'uG1', 'uG2'].forEach((n, i) => U3(poolP, n, pal[i]));
    gl.uniform2f(poolP.u.uR, W, H); gl.uniform1f(poolP.u.uT, clock); gl.uniform1f(poolP.u.uL, L); gl.drawArrays(gl.TRIANGLES, 0, 3);
    gl.enable(gl.BLEND); if (L) gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA); else gl.blendFunc(gl.ONE, gl.ONE);
    gl.useProgram(flyP.p); ['uC0', 'uC1', 'uC2'].forEach((n, i) => U3(flyP, n, pal[3 + i]));
    gl.uniform1f(flyP.u.uT, clock); gl.uniform1f(flyP.u.uD, d); gl.uniform1f(flyP.u.uL, L);
    gl.drawArrays(gl.POINTS, 0, W / d < 700 ? 70 : 130);
  }
  // 60 frames a second at the top of the page, 30 further down, none while the tab is hidden
  let last = performance.now(), acc = 0;
  function frame(t) {
    const dt = Math.min(100, t - last); last = t; acc += dt;
    const budget = scrollY > innerHeight * .8 ? 33 : 0;
    if (!document.hidden && acc >= budget) { draw(Math.min(50, acc)); acc = 0; }
    requestAnimationFrame(frame);
  }
  addEventListener('resize', () => { size(); if (reduce) draw(0); });
  size();
  if (reduce) { clock = 20000; draw(0); setInterval(() => draw(0), 1000); } // still, but follows a Colorway or theme change
  else requestAnimationFrame(frame);
  window.__flow = { draw };
})();
