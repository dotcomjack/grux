import wave, struct, sys, math
def load(path):
    w = wave.open(path)
    n, sw, ch, sr = w.getnframes(), w.getsampwidth(), w.getnchannels(), w.getframerate()
    raw = w.readframes(n)
    fmt = {1:'b', 2:'h', 4:'i'}[sw]
    data = struct.unpack('<%d%s' % (len(raw)//sw, fmt), raw)
    full = float(1 << (8*sw - 1))
    # de-interleave, keep the hottest channel
    chans = [data[c::ch] for c in range(ch)]
    best = max(chans, key=lambda x: sum(abs(v) for v in x))
    return [v/full for v in best], sr, n, ch
def rms(x):
    return math.sqrt(sum(v*v for v in x)/len(x)) if x else 0.0
def envelope(x, sr, win=0.25):
    step = int(sr*win); out=[]
    for i in range(0, len(x)-step+1, step):
        out.append((i/sr, rms(x[i:i+step])))
    return out
if __name__ == '__main__':
    path = sys.argv[1]
    x, sr, n, ch = load(path)
    print("%s: %d frames @%dHz %dch  dur=%.2fs  overall rms=%.6f" % (path, n, sr, ch, n/sr, rms(x)))
    silent = 0
    for t, r in envelope(x, sr):
        db = 20*math.log10(max(r,1e-9))
        mark = "  <-- SILENT" if r < 0.0005 else ""
        if r < 0.0005: silent += 1
        print("   t=%5.2fs rms=%.6f %7.1fdB %s%s" % (t, r, db, "#"*max(0,min(40,int((db+70)/1.5))), mark))
    print("   silent windows: %d" % silent)
