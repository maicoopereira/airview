package br.com.maico.projetartv;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;
import android.provider.Settings;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.KeyPair;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;

/**
 * Serviço leve que fica ligado desde o boot da TV: anuncia a TV na rede (Bonjour) e obedece ao app AirView do Mac.
 *
 * Protocolo de controle (linhas de texto; a TV abre com "AIRVIEW 1 <desafio>"):
 *   PING                                         → "OK <nome da TV>"
 *   PAIR <idMac> <nome b64> <chave pública b64>  → "PUB <chave pública da TV>"; depois o Mac manda
 *        CONFIRM <prova>, a TV mostra o código e espera OK no controle → "OK <prova da TV>" ou "ERRO"
 *   CONNECT <idMac> <porta> <nome b64> <chave da sessão cifrada b64> <hmac>   abre a projeção
 *   DISCONNECT <idMac> <hmac>                                                  fecha a projeção
 * CONNECT e DISCONNECT exigem HMAC(chave de pareamento, desafio + comando): só Macs pareados, sem repetição.
 */
public class ControlService extends Service {
    static final String TAG = "AirView";
    static final int CONTROL_PORT = 7071;
    static final String SERVICE_TYPE = "_projetartv-tv._tcp.";
    private static final String CHANNEL = "airview";
    private static final int MAX_LINE = 4096;

    /** Sessão que a tela de projeção deve abrir (passada em memória, nunca por Intent, que outros apps poderiam forjar). */
    static final class PendingSession {
        final String host;
        final int port;
        final String macName;
        final byte[] sessionKey;

        PendingSession(String host, int port, String macName, byte[] sessionKey) {
            this.host = host;
            this.port = port;
            this.macName = macName;
            this.sessionKey = sessionKey;
        }
    }

    private static PendingSession pending;

    static synchronized PendingSession takePendingSession() {
        PendingSession session = pending;
        pending = null;
        return session;
    }

    /** Pedido de pareamento esperando OK no controle (mostrado pela PairActivity). */
    static final class PairRequest {
        final String macName;
        final String code;
        final CountDownLatch answered = new CountDownLatch(1);
        volatile boolean accepted;

        PairRequest(String macName, String code) {
            this.macName = macName;
            this.code = code;
        }
    }

    private static volatile PairRequest currentPairRequest;

    static PairRequest currentPairRequest() {
        return currentPairRequest;
    }

    private volatile boolean running;
    private ServerSocket server;
    private NsdManager nsd;
    private NsdManager.RegistrationListener registration;
    /** No máximo 4 conversas de controle ao mesmo tempo (contra enxurrada de conexões). */
    private final Semaphore slots = new Semaphore(4);

    /** Inicia o serviço (no boot, ou ao abrir o app). */
    static void start(Context context) {
        Intent intent = new Intent(context, ControlService.class);
        if (Build.VERSION.SDK_INT >= 26) {
            context.startForegroundService(intent);
        } else {
            context.startService(intent);
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        // Serviço em primeiro plano: o Android não o encerra em segundo plano (a notificação não aparece na TV).
        startForeground(1, notification());
        running = true;
        new Thread(this::serve, "controle").start();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        return START_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onDestroy() {
        running = false;
        try {
            if (server != null) server.close();
        } catch (IOException ignored) {
        }
        if (nsd != null && registration != null) {
            try {
                nsd.unregisterService(registration);
            } catch (RuntimeException ignored) {
            }
        }
        super.onDestroy();
    }

    private Notification notification() {
        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager manager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
            manager.createNotificationChannel(
                    new NotificationChannel(CHANNEL, "AirView", NotificationManager.IMPORTANCE_MIN));
            builder = new Notification.Builder(this, CHANNEL);
        } else {
            builder = new Notification.Builder(this);
        }
        return builder.setSmallIcon(R.drawable.icon)
                .setContentTitle("AirView")
                .setContentText("Pronta para receber a tela do Mac")
                .build();
    }

    private void serve() {
        try {
            server = new ServerSocket();
            server.setReuseAddress(true);
            server.bind(new InetSocketAddress(CONTROL_PORT));
        } catch (IOException e) {
            Log.w(TAG, "porta de controle indisponível", e);
            stopSelf();
            return;
        }
        advertise();
        while (running) {
            Socket client;
            try {
                client = server.accept();
            } catch (IOException e) {
                if (!running) return;
                continue;
            }
            if (!slots.tryAcquire()) {
                closeQuietly(client);
                continue;
            }
            new Thread(() -> {
                try {
                    handle(client);
                } finally {
                    slots.release();
                }
            }, "controle-cliente").start();
        }
    }

    private void advertise() {
        NsdServiceInfo info = new NsdServiceInfo();
        info.setServiceName(deviceName());
        info.setServiceType(SERVICE_TYPE);
        info.setPort(CONTROL_PORT);
        nsd = (NsdManager) getSystemService(Context.NSD_SERVICE);
        registration = new NsdManager.RegistrationListener() {
            @Override
            public void onRegistrationFailed(NsdServiceInfo serviceInfo, int errorCode) {
                Log.w(TAG, "anúncio na rede falhou: " + errorCode);
            }

            @Override
            public void onUnregistrationFailed(NsdServiceInfo serviceInfo, int errorCode) {
            }

            @Override
            public void onServiceRegistered(NsdServiceInfo serviceInfo) {
                Log.i(TAG, "anunciada na rede como " + serviceInfo.getServiceName());
            }

            @Override
            public void onServiceUnregistered(NsdServiceInfo serviceInfo) {
            }
        };
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, registration);
    }

    private String deviceName() {
        String name = Settings.Global.getString(getContentResolver(), "device_name");
        return name != null && !name.isEmpty() ? name : Build.MODEL;
    }

    // ----- Conversa de controle -----

    private void handle(Socket client) {
        try (Socket s = client) {
            s.setSoTimeout(5000);
            InputStream in = s.getInputStream();
            OutputStream out = s.getOutputStream();
            byte[] challenge = Crypto.random(16);
            send(out, "AIRVIEW 1 " + Crypto.b64(challenge));

            String line = readLine(in);
            if (line == null) return;
            String[] parts = line.split(" ");
            switch (parts[0]) {
                case "PING":
                    send(out, "OK " + deviceName());
                    break;
                case "PAIR":
                    pair(s, in, out, parts);
                    break;
                case "CONNECT":
                case "DISCONNECT":
                    send(out, authorized(line, parts, challenge) ? execute(parts, s) : "ERRO não pareado");
                    break;
                default:
                    send(out, "ERRO comando desconhecido");
            }
        } catch (IOException | RuntimeException | GeneralSecurityException e) {
            Log.w(TAG, "conversa de controle encerrada: " + e);
        }
    }

    /** O último campo é HMAC(chave do Mac, desafio + resto da linha). */
    private boolean authorized(String line, String[] parts, byte[] challenge) throws GeneralSecurityException {
        if (parts.length < 3) return false;
        byte[] key = pairingKey(parts[1]);
        if (key == null) return false;
        String command = line.substring(0, line.lastIndexOf(' '));
        byte[] expected = Crypto.hmac(key, null, challenge, command.getBytes(StandardCharsets.UTF_8));
        return Crypto.equals(expected, Crypto.unb64(parts[parts.length - 1]));
    }

    private String execute(String[] parts, Socket s) throws GeneralSecurityException {
        if (parts[0].equals("DISCONNECT")) {
            MainActivity.closeIfOpen();
            return "OK";
        }
        if (parts.length != 6) return "ERRO formato";
        int port = Integer.parseInt(parts[2]);
        if (port < 1 || port > 65535) return "ERRO porta";
        String macName = new String(Crypto.unb64(parts[3]), StandardCharsets.UTF_8);
        if (macName.length() > 64) macName = macName.substring(0, 64);
        byte[] sessionKey = Crypto.openCombined(pairingKey(parts[1]), Crypto.unb64(parts[4]));
        if (sessionKey.length != 32) return "ERRO chave";
        openProjection(s.getInetAddress().getHostAddress(), port, macName, sessionKey);
        return "OK";
    }

    private void pair(Socket s, InputStream in, OutputStream out, String[] parts)
            throws IOException, GeneralSecurityException {
        if (parts.length != 4 || parts[1].length() > 64) {
            send(out, "ERRO formato");
            return;
        }
        if (currentPairRequest != null) {
            send(out, "ERRO ocupado");
            return;
        }
        String macId = parts[1];
        String macName = new String(Crypto.unb64(parts[2]), StandardCharsets.UTF_8);
        if (macName.length() > 64) macName = macName.substring(0, 64);
        KeyPair keys = Crypto.newKeyPair();
        byte[] key = Crypto.pairingKey(keys.getPrivate(), Crypto.unb64(parts[3]));
        send(out, "PUB " + Crypto.b64(keys.getPublic().getEncoded()));

        String confirm = readLine(in);
        if (confirm == null || !confirm.startsWith("CONFIRM ")
                || !Crypto.equals(Crypto.unb64(confirm.substring(8)), Crypto.hmac(key, "airview-confirm"))) {
            send(out, "ERRO prova");
            return;
        }

        // Mostra o código e espera alguém aceitar com OK no controle (até 90 s).
        PairRequest request = new PairRequest(macName, Crypto.verificationCode(key));
        currentPairRequest = request;
        try {
            wakeScreen();
            startActivity(new Intent(this, PairActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            s.setSoTimeout(95_000);
            boolean answered = request.answered.await(90, TimeUnit.SECONDS);
            if (answered && request.accepted) {
                savePairing(macId, macName, key);
                send(out, "OK " + Crypto.b64(Crypto.hmac(key, "airview-tv-ok")));
            } else {
                send(out, "ERRO recusado");
            }
        } catch (InterruptedException e) {
            send(out, "ERRO recusado");
        } finally {
            currentPairRequest = null;
            PairActivity.closeIfOpen();
        }
    }

    // ----- Pareamentos guardados -----

    private SharedPreferences pairings() {
        return getSharedPreferences("pareamentos", MODE_PRIVATE);
    }

    private byte[] pairingKey(String macId) {
        String stored = pairings().getString("k." + macId, null);
        return stored == null ? null : Crypto.unb64(stored);
    }

    private void savePairing(String macId, String macName, byte[] key) {
        pairings().edit().putString("k." + macId, Crypto.b64(key)).putString("n." + macId, macName).apply();
    }

    // ----- Utilitários -----

    /** Lê uma linha de até 4 KB; null se a conexão fechar ou a linha for grande demais. */
    private static String readLine(InputStream in) throws IOException {
        ByteArrayOutputStream line = new ByteArrayOutputStream();
        while (line.size() <= MAX_LINE) {
            int b = in.read();
            if (b < 0) return null;
            if (b == '\n') return line.toString("UTF-8").trim();
            line.write(b);
        }
        return null;
    }

    private static void send(OutputStream out, String line) throws IOException {
        out.write((line + "\n").getBytes(StandardCharsets.UTF_8));
        out.flush();
    }

    private static void closeQuietly(Socket s) {
        try {
            s.close();
        } catch (IOException ignored) {
        }
    }

    /** Acorda a tela (sai do protetor de tela). */
    @SuppressWarnings("deprecation")
    private void wakeScreen() {
        PowerManager power = (PowerManager) getSystemService(POWER_SERVICE);
        PowerManager.WakeLock wake = power.newWakeLock(PowerManager.SCREEN_BRIGHT_WAKE_LOCK
                | PowerManager.ACQUIRE_CAUSES_WAKEUP | PowerManager.ON_AFTER_RELEASE, "airview:acordar");
        wake.acquire(5000);
    }

    /** Abre a projeção apontando para o Mac que mandou o comando. */
    private void openProjection(String host, int port, String macName, byte[] sessionKey) {
        synchronized (ControlService.class) {
            pending = new PendingSession(host, port, macName, sessionKey);
        }
        wakeScreen();
        startActivity(new Intent(this, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra("sessao", true));
    }
}
