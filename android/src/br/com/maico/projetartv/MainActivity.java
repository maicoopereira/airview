package br.com.maico.projetartv;

import android.app.Activity;
import android.content.Intent;
import android.animation.ObjectAnimator;
import android.animation.ValueAnimator;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.lang.ref.WeakReference;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.util.Arrays;
import java.util.HashMap;
import java.util.concurrent.LinkedBlockingDeque;
import java.util.concurrent.TimeUnit;

/**
 * Recebe vídeo H.264 + áudio PCM do Mac (ProjetarTV) e exibe em tela cheia, com imagem e som sincronizados.
 * Protocolo: tipo (1 byte) | tamanho (int) | pts µs (long) | payload — ver mac/Sources/ProjetarTV/StreamServer.swift.
 */
public class MainActivity extends Activity implements SurfaceHolder.Callback {
    private static final String TAG = "ProjetarTV";
    private static final int MSG_VIDEO_CONFIG = 1;
    private static final int MSG_VIDEO_FRAME = 2;
    private static final int MSG_AUDIO_CONFIG = 3;
    private static final int MSG_AUDIO_DATA = 4;
    private static final int MSG_DEVICE_NAME = 5;
    /** Maior quadro aceito (um quadro-chave 1080p tem ~0,5 MB); acima disso é erro ou ataque. */
    private static final int MAX_FRAME = 16 << 20;
    /**
     * Quanto a imagem pode adiantar o som sem o ouvido perceber (limite usual de radiodifusão).
     * O vídeo só espera o áudio além disso, para não ficar mais atrasado que o necessário em relação ao Mac.
     */
    private static final long AUDIO_LAG_ALLOWED_US = 60_000;

    private FrameLayout root;
    private SurfaceView surfaceView;
    private View overlay;
    private TextView status;
    private ObjectAnimator pulse;
    private int videoWidth, videoHeight;

    /** Transmissão ativa. Cada vez que a superfície de vídeo é criada nasce uma nova; a antiga é descartada. */
    private Session session;
    private Surface surface;

    /** Sessão entregue pelo ControlService (endereço, nome e chave do Mac). Sem ela, só mostra "Aguardando conexão". */
    private ControlService.PendingSession target;

    private static WeakReference<MainActivity> current = new WeakReference<>(null);

    /** O Mac pediu para desconectar (comando DISCONNECT autenticado no ControlService). */
    static void closeIfOpen() {
        MainActivity activity = current.get();
        if (activity != null) activity.runOnUiThread(activity::finish);
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        if (Build.VERSION.SDK_INT >= 27) {
            // Aberto pelo Mac com a TV no protetor de tela: acende e fica por cima.
            setTurnScreenOn(true);
            setShowWhenLocked(true);
        }
        ControlService.start(this);
        current = new WeakReference<>(this);
        target = ControlService.takePendingSession();

        root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);

        surfaceView = new SurfaceView(this);
        surfaceView.getHolder().addCallback(this);
        root.addView(surfaceView, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER));

        overlay = buildOverlay();
        root.addView(overlay, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        setContentView(root);
        hideSystemUi();
        setStatus(getString(R.string.aguardando));
    }

    /** O Mac pediu para conectar de novo (talvez outro Mac): recomeça com a sessão nova. */
    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        ControlService.PendingSession next = ControlService.takePendingSession();
        if (next == null) return;
        target = next;
        if (surface != null) {
            if (session != null) session.stop();
            session = new Session(surface, target);
            session.start();
        }
    }

    private void hideSystemUi() {
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN
                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                | View.SYSTEM_UI_FLAG_LAYOUT_STABLE);
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        if (session != null) session.stop();
        surface = holder.getSurface();
        session = new Session(surface, target);
        session.start();
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        if (session != null) {
            session.stop();
            session = null;
        }
        surface = null;
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_DPAD_CENTER || keyCode == KeyEvent.KEYCODE_ENTER) {
            // OK no controle mostra/oculta as informações da conexão.
            overlay.setVisibility(overlay.getVisibility() == View.VISIBLE ? View.GONE : View.VISIBLE);
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    // ---------- Sessão de transmissão ----------

    private static final class VideoItem {
        final boolean config;
        final byte[] data;
        final long ptsUs;

        VideoItem(boolean config, byte[] data, long ptsUs) {
            this.config = config;
            this.data = data;
            this.ptsUs = ptsUs;
        }
    }

    /**
     * Tudo de uma transmissão: busca do Mac, conexões, decodificador e áudio. Não compartilha estado com
     * sessões anteriores, então parar uma (sair do app, superfície destruída) nunca trava a próxima.
     */
    private final class Session {
        private final Surface surface;
        private final ControlService.PendingSession target;
        private volatile boolean active = true;
        private volatile Socket socket;
        private Thread networkThread;

        // Por conexão
        private final AudioPlayer audio = new AudioPlayer();
        private final LinkedBlockingDeque<VideoItem> videoQueue = new LinkedBlockingDeque<>();
        /** Quando cada quadro entrou no decodificador, para medir quanto ele demora. */
        private final HashMap<Long, Long> inputTimes = new HashMap<>();
        private volatile long decodeLatencyUs = 50_000;
        /** Correção aprendida: quanto antes alimentar o decodificador para o quadro sair junto com o som. */
        private volatile long syncOffsetUs;
        private volatile String macName;
        private volatile MediaCodec decoder;
        private Thread outputThread;
        private byte[] currentConfig;
        private volatile boolean firstFrameShown;
        private long lastSyncLog;

        Session(Surface surface, ControlService.PendingSession target) {
            this.surface = surface;
            this.target = target;
            macName = target != null ? target.macName : null;
        }

        void start() {
            networkThread = new Thread(this::networkLoop, "rede");
            networkThread.start();
        }

        /** Para sem esperar a limpeza: a thread de rede encerra o resto sozinha. */
        void stop() {
            active = false;
            closeSocket();
            if (networkThread != null) networkThread.interrupt();
        }

        private void closeSocket() {
            Socket s = socket;
            if (s != null) {
                try {
                    s.close();
                } catch (IOException ignored) {
                }
            }
        }

        // ----- Rede -----

        private void networkLoop() {
            if (target == null) {
                // Aberta pelo usuário, sem pedido do Mac: só espera (a TV não procura Macs sozinha).
                setStatus(getString(R.string.aguardando));
                return;
            }
            InetSocketAddress address = new InetSocketAddress(target.host, target.port);
            int failures = 0;
            while (active && failures < 10) {
                Socket s = new Socket();
                socket = s;
                Thread feeder = null;
                try {
                    setStatus(getString(R.string.conectando, macName));
                    s.setTcpNoDelay(true);
                    s.setReceiveBufferSize(1 << 20);
                    s.connect(address, 3000);
                    // Sem dados por 5 s (o Mac manda ao menos 30 quadros/s) = conexão morta.
                    s.setSoTimeout(5000);
                    DataInputStream in = new DataInputStream(new BufferedInputStream(s.getInputStream(), 1 << 16));
                    Crypto.StreamDecryptor decryptor = handshake(in, s.getOutputStream());
                    failures = 0;
                    firstFrameShown = false;
                    feeder = new Thread(this::feedLoop, "video-entrada");
                    feeder.start();
                    readLoop(in, decryptor);
                } catch (IOException | GeneralSecurityException e) {
                    Log.i(TAG, "conexão encerrada: " + e);
                    failures++;
                    if (active) setStatus(getString(R.string.aguardando));
                } finally {
                    closeSocket();
                    socket = null;
                    if (feeder != null) {
                        feeder.interrupt();
                        joinQuietly(feeder, 1000);
                    }
                    videoQueue.clear();
                    releaseDecoder();
                    audio.stop();
                }
                sleep(1000);
            }
        }

        /** Prova ao Mac que esta TV recebeu a chave da sessão e prepara a decifragem desta conexão. */
        private Crypto.StreamDecryptor handshake(DataInputStream in, java.io.OutputStream out)
                throws IOException, GeneralSecurityException {
            byte[] hello = new byte[20];
            in.readFully(hello);
            if (hello[0] != 'A' || hello[1] != 'V' || hello[2] != 'W' || hello[3] != '1') {
                throw new IOException("servidor desconhecido");
            }
            byte[] challenge = Arrays.copyOfRange(hello, 4, 20);
            out.write(Crypto.hmac(target.sessionKey, "airview-hello", challenge));
            out.flush();
            return new Crypto.StreamDecryptor(target.sessionKey, challenge);
        }

        /** Quadros cifrados: tamanho (int) | mensagem cifrada + tag. Qualquer alteração derruba a conexão. */
        private void readLoop(DataInputStream in, Crypto.StreamDecryptor decryptor)
                throws IOException, GeneralSecurityException {
            byte[] frame = new byte[1 << 20];
            byte[] buffer = new byte[1 << 20];
            while (active) {
                int frameLength = in.readInt();
                if (frameLength < 13 + 16 || frameLength > MAX_FRAME) throw new IOException("quadro inválido");
                if (frame.length < frameLength) frame = new byte[frameLength];
                if (buffer.length < frameLength) buffer = new byte[frameLength];
                in.readFully(frame, 0, frameLength);
                int plainLength = decryptor.open(frame, frameLength, buffer);

                ByteBuffer header = ByteBuffer.wrap(buffer, 0, 13);
                int type = header.get() & 0xff;
                int length = header.getInt();
                long pts = header.getLong();
                if (length < 0 || length != plainLength - 13) throw new IOException("mensagem inválida");
                System.arraycopy(buffer, 13, buffer, 0, length);

                switch (type) {
                    case MSG_VIDEO_CONFIG:
                        videoQueue.offer(new VideoItem(true, Arrays.copyOf(buffer, length), 0));
                        break;
                    case MSG_VIDEO_FRAME:
                        // byte 0 = flag de quadro-chave; o resto é H.264 Annex B
                        if (length > 1) videoQueue.offer(new VideoItem(false, Arrays.copyOfRange(buffer, 1, length), pts));
                        break;
                    case MSG_AUDIO_CONFIG: {
                        if (length < 5) throw new IOException("mensagem inválida");
                        ByteBuffer b = ByteBuffer.wrap(buffer, 0, length);
                        int rate = b.getInt();
                        int channels = b.get() & 0xff;
                        if (rate < 8000 || rate > 192000 || channels < 1 || channels > 2) {
                            throw new IOException("formato de áudio inválido");
                        }
                        audio.configure(rate, channels);
                        break;
                    }
                    case MSG_AUDIO_DATA:
                        audio.write(buffer, length, pts);
                        break;
                    case MSG_DEVICE_NAME:
                        macName = new String(buffer, 0, Math.min(length, 64), StandardCharsets.UTF_8);
                        if (!firstFrameShown) setStatus(getString(R.string.conectando, macName));
                        break;
                    default:
                        break; // tipos futuros são ignorados
                }
                // Fila de vídeo cheia = o decodificador não acompanha (ou alguém tenta esgotar a memória).
                if (videoQueue.size() > 240) videoQueue.clear();
            }
        }

        // ----- Vídeo -----

        /**
         * Alimenta o decodificador no ritmo do áudio: cada quadro entra quando o áudio do mesmo instante
         * estiver para tocar, descontado o tempo que o decodificador leva. Assim imagem e som saem juntos.
         */
        private void feedLoop() {
            while (active) {
                VideoItem item;
                try {
                    item = videoQueue.poll(100, TimeUnit.MILLISECONDS);
                } catch (InterruptedException e) {
                    return;
                }
                if (item == null) continue;
                try {
                    if (item.config) {
                        configureDecoder(item.data);
                    } else {
                        if (!waitForAudio(item.ptsUs)) return;
                        queueFrame(item);
                    }
                } catch (IOException | RuntimeException e) {
                    Log.w(TAG, "decodificador falhou", e);
                    closeSocket(); // reconecta e recomeça do zero
                    return;
                }
            }
        }

        /** Espera até a hora de decodificar o quadro. Devolve false se a thread foi interrompida. */
        private boolean waitForAudio(long ptsUs) {
            while (active) {
                long audioNow = audio.currentPtsUs(System.nanoTime());
                if (audioNow == Long.MIN_VALUE) return true; // sem áudio tocando: mostra já
                long waitUs = ptsUs - audioNow - decodeLatencyUs - syncOffsetUs - AUDIO_LAG_ALLOWED_US;
                // Na hora, atrasado, ou relógios incoerentes (> 1 s): não segura o quadro.
                if (waitUs <= 2_000 || waitUs > 1_000_000 || videoQueue.size() > 90) return true;
                try {
                    Thread.sleep(Math.min(waitUs / 1000, 20));
                } catch (InterruptedException e) {
                    return false;
                }
            }
            return false;
        }

        private void configureDecoder(byte[] config) throws IOException {
            if (decoder != null && Arrays.equals(config, currentConfig)) return;
            ByteBuffer b = ByteBuffer.wrap(config);
            int width = b.getShort() & 0xffff;
            int height = b.getShort() & 0xffff;
            byte[] sps = new byte[b.getShort() & 0xffff];
            b.get(sps);
            byte[] pps = new byte[b.getShort() & 0xffff];
            b.get(pps);

            releaseDecoder();
            MediaFormat format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height);
            format.setByteBuffer("csd-0", ByteBuffer.wrap(withStartCode(sps)));
            format.setByteBuffer("csd-1", ByteBuffer.wrap(withStartCode(pps)));
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, width * height);
            if (Build.VERSION.SDK_INT >= 23) format.setInteger(MediaFormat.KEY_PRIORITY, 0); // tempo real
            if (Build.VERSION.SDK_INT >= 30) format.setInteger("low-latency", 1);

            MediaCodec codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
            try {
                codec.configure(format, surface, null, 0);
            } catch (RuntimeException e) {
                // Alguns decodificadores recusam chaves opcionais; tenta sem elas.
                codec.reset();
                format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height);
                format.setByteBuffer("csd-0", ByteBuffer.wrap(withStartCode(sps)));
                format.setByteBuffer("csd-1", ByteBuffer.wrap(withStartCode(pps)));
                codec.configure(format, surface, null, 0);
            }
            codec.start();

            currentConfig = config;
            decoder = codec;
            outputThread = new Thread(() -> drainOutput(codec), "video-saida");
            outputThread.start();
            runOnUiThread(() -> fitVideo(width, height));
        }

        private void queueFrame(VideoItem item) {
            MediaCodec codec = decoder;
            if (codec == null) return;
            int index = codec.dequeueInputBuffer(100_000);
            if (index < 0) return; // decodificador atrasado: descarta o quadro
            ByteBuffer input = codec.getInputBuffer(index);
            input.clear();
            input.put(item.data);
            synchronized (inputTimes) {
                if (inputTimes.size() > 300) inputTimes.clear();
                inputTimes.put(item.ptsUs, System.nanoTime());
            }
            codec.queueInputBuffer(index, 0, item.data.length, item.ptsUs, 0);
        }

        private void drainOutput(MediaCodec codec) {
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            while (active && decoder == codec) {
                try {
                    int index = codec.dequeueOutputBuffer(info, 10_000);
                    if (index < 0) continue;
                    long now = System.nanoTime();
                    Long queuedAt;
                    synchronized (inputTimes) {
                        queuedAt = inputTimes.remove(info.presentationTimeUs);
                    }
                    if (queuedAt != null) {
                        long sampleUs = (now - queuedAt) / 1000;
                        decodeLatencyUs = (decodeLatencyUs * 7 + sampleUs) / 8;
                    }
                    // Ajuste fino: se o quadro saiu um pouco antes do áudio, agenda a exibição para o instante certo.
                    long audioNow = audio.currentPtsUs(now);
                    long earlyUs = audioNow == Long.MIN_VALUE ? 0 : info.presentationTimeUs - audioNow;
                    if (audioNow != Long.MIN_VALUE && Math.abs(earlyUs) < 1_000_000) {
                        // Atraso médio que sobra entre decodificar e chegar à tela: corrige aos poucos.
                        // Imagem adiantada demais em relação ao som → alimenta mais tarde; atrasada → mais cedo.
                        long next = syncOffsetUs - (earlyUs - AUDIO_LAG_ALLOWED_US) / 20;
                        syncOffsetUs = Math.max(-200_000, Math.min(300_000, next));
                    }
                    long holdUs = earlyUs - AUDIO_LAG_ALLOWED_US;
                    if (holdUs > 2_000 && holdUs < 100_000) {
                        codec.releaseOutputBuffer(index, now + holdUs * 1000);
                    } else {
                        codec.releaseOutputBuffer(index, true);
                    }
                    if (now - lastSyncLog > 5_000_000_000L) {
                        lastSyncLog = now;
                        Log.i(TAG, "sync: video-audio=" + (audioNow == Long.MIN_VALUE ? "sem audio" : (-earlyUs / 1000) + "ms")
                                + " decodificador=" + decodeLatencyUs / 1000 + "ms correcao=" + syncOffsetUs / 1000
                                + "ms fila=" + videoQueue.size() + " | " + audio.describe(now));
                    }
                    if (!firstFrameShown) {
                        firstFrameShown = true;
                        runOnUiThread(() -> showOverlay(false));
                    }
                } catch (IllegalStateException e) {
                    return;
                }
            }
        }

        private void releaseDecoder() {
            MediaCodec codec = decoder;
            decoder = null;
            currentConfig = null;
            Thread t = outputThread;
            outputThread = null;
            if (t != null) joinQuietly(t, 500);
            if (codec != null) {
                try {
                    codec.stop();
                } catch (RuntimeException ignored) {
                }
                codec.release();
            }
            synchronized (inputTimes) {
                inputTimes.clear();
            }
        }
    }

    // ---------- Utilitários ----------

    private static byte[] withStartCode(byte[] nal) {
        byte[] out = new byte[nal.length + 4];
        out[3] = 1;
        System.arraycopy(nal, 0, out, 4, nal.length);
        return out;
    }

    /** Ajusta a SurfaceView à proporção do vídeo (barras pretas se necessário). */
    private void fitVideo(int width, int height) {
        if (width == videoWidth && height == videoHeight) return;
        int w = root.getWidth(), h = root.getHeight();
        if (w == 0 || h == 0) return;
        videoWidth = width;
        videoHeight = height;
        float scale = Math.min((float) w / width, (float) h / height);
        surfaceView.setLayoutParams(new FrameLayout.LayoutParams(
                Math.round(width * scale), Math.round(height * scale), Gravity.CENTER));
    }

    private void setStatus(final String text) {
        runOnUiThread(() -> {
            status.setText(text);
            showOverlay(true);
        });
    }

    private void showOverlay(boolean visible) {
        overlay.setVisibility(visible ? View.VISIBLE : View.GONE);
        if (visible && !pulse.isStarted()) pulse.start();
        if (!visible) pulse.cancel();
    }

    private float dp(float value) {
        return TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, getResources().getDisplayMetrics());
    }

    /**
     * Tela de espera no estilo vidro do macOS: fundo azul do ícone, cartão translúcido com borda clara,
     * ícone pulsando devagar e uma frase só.
     */
    private View buildOverlay() {
        FrameLayout background = new FrameLayout(this);
        GradientDrawable gradient = new GradientDrawable(GradientDrawable.Orientation.TL_BR,
                new int[]{0xFF38C8F8, 0xFF2F7BF5, 0xFF1747C8});
        background.setBackground(gradient);

        // Luz difusa atrás do cartão
        View glow = new View(this);
        GradientDrawable glowShape = new GradientDrawable();
        glowShape.setShape(GradientDrawable.OVAL);
        glowShape.setGradientType(GradientDrawable.RADIAL_GRADIENT);
        glowShape.setGradientRadius(dp(260));
        glowShape.setColors(new int[]{0x55FFFFFF, 0x00FFFFFF});
        glow.setBackground(glowShape);
        background.addView(glow, new FrameLayout.LayoutParams((int) dp(560), (int) dp(560), Gravity.CENTER));

        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setGravity(Gravity.CENTER);
        int padH = (int) dp(64), padV = (int) dp(44);
        card.setPadding(padH, padV, padH, padV);
        GradientDrawable glass = new GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM,
                new int[]{0x4DFFFFFF, 0x1AFFFFFF});
        glass.setCornerRadius(dp(36));
        glass.setStroke((int) dp(1.5f), 0x66FFFFFF);
        card.setBackground(glass);
        card.setElevation(dp(12));

        ImageView icon = new ImageView(this);
        icon.setImageResource(R.drawable.icon);
        card.addView(icon, new LinearLayout.LayoutParams((int) dp(112), (int) dp(112)));
        pulse = ObjectAnimator.ofFloat(icon, View.ALPHA, 1f, 0.55f);
        pulse.setDuration(1400);
        pulse.setRepeatMode(ValueAnimator.REVERSE);
        pulse.setRepeatCount(ValueAnimator.INFINITE);

        status = new TextView(this);
        status.setTextColor(Color.WHITE);
        status.setTextSize(TypedValue.COMPLEX_UNIT_SP, 30);
        status.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        status.setGravity(Gravity.CENTER);
        status.setShadowLayer(dp(6), 0, dp(1), 0x40061F4F);
        LinearLayout.LayoutParams textParams = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        textParams.topMargin = (int) dp(24);
        card.addView(status, textParams);

        background.addView(card, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER));
        return background;
    }

    private static void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException ignored) {
        }
    }

    private static void joinQuietly(Thread t, long ms) {
        try {
            t.join(ms);
        } catch (InterruptedException ignored) {
        }
    }
}
