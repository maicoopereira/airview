package br.com.maico.projetartv;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTimestamp;
import android.media.AudioTrack;
import android.os.Build;

import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.concurrent.LinkedBlockingDeque;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Toca PCM 16-bit intercalado num AudioTrack e serve de relógio mestre: {@link #currentPtsUs(long)} diz qual
 * instante do Mac está saindo no alto-falante agora, e o vídeo se alinha a isso.
 *
 * Um pequeno buffer de folga absorve as oscilações do Wi-Fi (evita cortes); se acumular demais,
 * descarta o áudio mais antigo para não deixar o atraso crescer.
 */
final class AudioPlayer {
    /** Folga acumulada antes de começar a tocar (e após um esvaziamento). */
    private static final int PREFILL_MS = 30;
    /** Acima disso de áudio na fila, descarta o mais antigo até voltar à folga. */
    private static final int MAX_QUEUED_MS = 80;
    /** Buffer inicial do AudioTrack; cresce sozinho se houver falhas (underruns). */
    private static final int START_BUFFER_MS = 40;
    private static final int MAX_BUFFER_MS = 120;

    private static final class Chunk {
        final byte[] data;
        final long ptsUs;

        Chunk(byte[] data, long ptsUs) {
            this.data = data;
            this.ptsUs = ptsUs;
        }
    }

    /** Em que quadro do AudioTrack começou cada bloco escrito, e o PTS do Mac correspondente. */
    private static final class Mark {
        final long frame;
        final long ptsUs;

        Mark(long frame, long ptsUs) {
            this.frame = frame;
            this.ptsUs = ptsUs;
        }
    }

    private final LinkedBlockingDeque<Chunk> queue = new LinkedBlockingDeque<>();
    private final AtomicInteger queuedBytes = new AtomicInteger();
    private final ArrayDeque<Mark> marks = new ArrayDeque<>();
    private final AudioTimestamp timestamp = new AudioTimestamp();
    private AudioTrack track;
    private Thread thread;
    private volatile boolean playing;
    private int sampleRate, channels, bytesPerFrame, prefillBytes, maxQueuedBytes;
    private long framesWritten;
    private volatile long lastReceivedPtsUs = Long.MIN_VALUE;
    private int bufferBytes;
    private int lastUnderruns;

    synchronized void configure(int sampleRate, int channels) {
        if (track != null && sampleRate == this.sampleRate && channels == this.channels) return;
        stop();
        this.sampleRate = sampleRate;
        this.channels = channels;
        bytesPerFrame = channels * 2;
        int bytesPerSecond = sampleRate * bytesPerFrame;
        prefillBytes = bytesPerSecond * PREFILL_MS / 1000;
        maxQueuedBytes = bytesPerSecond * MAX_QUEUED_MS / 1000;

        int channelMask = channels == 1 ? AudioFormat.CHANNEL_OUT_MONO : AudioFormat.CHANNEL_OUT_STEREO;
        int minBuffer = AudioTrack.getMinBufferSize(sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT);
        int capacity = Math.max(minBuffer, bytesPerSecond * MAX_BUFFER_MS / 1000);
        if (Build.VERSION.SDK_INT >= 26) {
            // Modo de baixa latência: o Android pode usar o mixer rápido e buffers menores.
            track = new AudioTrack.Builder()
                    .setAudioAttributes(new AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                            .build())
                    .setAudioFormat(new AudioFormat.Builder()
                            .setSampleRate(sampleRate)
                            .setChannelMask(channelMask)
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .build())
                    .setBufferSizeInBytes(capacity)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                    .build();
        } else {
            track = new AudioTrack(AudioManager.STREAM_MUSIC, sampleRate, channelMask,
                    AudioFormat.ENCODING_PCM_16BIT, capacity, AudioTrack.MODE_STREAM);
        }
        if (Build.VERSION.SDK_INT >= 24) {
            // Usa só uma parte da capacidade; adjustBuffer() aumenta se faltar.
            track.setBufferSizeInFrames(sampleRate * START_BUFFER_MS / 1000);
            lastUnderruns = track.getUnderrunCount();
        }
        bufferBytes = (Build.VERSION.SDK_INT >= 24 ? track.getBufferSizeInFrames() : capacity / bytesPerFrame) * bytesPerFrame;
        track.play();
        synchronized (marks) {
            marks.clear();
            framesWritten = 0;
        }

        playing = true;
        final AudioTrack t = track;
        thread = new Thread(() -> playLoop(t), "audio");
        thread.setPriority(Thread.MAX_PRIORITY);
        thread.start();
    }

    private void playLoop(AudioTrack t) {
        boolean prefilling = true;
        while (playing) {
            try {
                if (prefilling && queuedBytes.get() < prefillBytes) {
                    Thread.sleep(5);
                    continue;
                }
                prefilling = false;
                Chunk chunk = queue.poll(100, TimeUnit.MILLISECONDS);
                if (chunk == null) {
                    prefilling = true; // esvaziou (rede travou): junta folga de novo antes de voltar
                    continue;
                }
                queuedBytes.addAndGet(-chunk.data.length);
                synchronized (marks) {
                    marks.addLast(new Mark(framesWritten, chunk.ptsUs));
                    while (marks.size() > 200) marks.removeFirst();
                    framesWritten += chunk.data.length / bytesPerFrame;
                }
                t.write(chunk.data, 0, chunk.data.length);
                adjustBuffer(t);
            } catch (InterruptedException e) {
                return;
            }
        }
    }

    /** Se o AudioTrack esvaziou (som falhou), aumenta o buffer em 10 ms até o máximo. */
    private void adjustBuffer(AudioTrack t) {
        if (Build.VERSION.SDK_INT < 24) return;
        int underruns = t.getUnderrunCount();
        if (underruns == lastUnderruns) return;
        lastUnderruns = underruns;
        int frames = t.getBufferSizeInFrames() + sampleRate / 100;
        int max = sampleRate * MAX_BUFFER_MS / 1000;
        if (frames <= max) {
            t.setBufferSizeInFrames(frames);
            bufferBytes = t.getBufferSizeInFrames() * bytesPerFrame;
        }
    }

    void write(byte[] data, int length, long ptsUs) {
        if (!playing) return;
        lastReceivedPtsUs = ptsUs;
        queuedBytes.addAndGet(length);
        queue.offer(new Chunk(Arrays.copyOf(data, length), ptsUs));
        if (queuedBytes.get() > maxQueuedBytes) {
            // Atraso acumulado (ex.: rajada depois de um travamento): joga fora o mais antigo.
            while (queuedBytes.get() > prefillBytes) {
                Chunk old = queue.pollFirst();
                if (old == null) break;
                queuedBytes.addAndGet(-old.data.length);
            }
        }
    }

    /**
     * PTS do Mac (µs) que está sendo ouvido no instante {@code nowNs} (System.nanoTime), ou
     * {@code Long.MIN_VALUE} se ainda não dá para saber.
     */
    long currentPtsUs(long nowNs) {
        AudioTrack t;
        int rate;
        synchronized (this) {
            t = track;
            rate = sampleRate;
        }
        if (t == null || !playing) return Long.MIN_VALUE;

        long playedFrame;
        try {
            if (t.getTimestamp(timestamp) && timestamp.framePosition > 0) {
                playedFrame = timestamp.framePosition + (nowNs - timestamp.nanoTime) * rate / 1_000_000_000L;
            } else {
                playedFrame = t.getPlaybackHeadPosition() & 0xffffffffL;
            }
        } catch (IllegalStateException e) {
            return Long.MIN_VALUE;
        }

        synchronized (marks) {
            if (marks.isEmpty() || playedFrame > framesWritten) return Long.MIN_VALUE; // tocando silêncio
            Mark found = null;
            for (Mark m : marks) {
                if (m.frame > playedFrame) break;
                found = m;
            }
            if (found == null) return Long.MIN_VALUE;
            return found.ptsUs + (playedFrame - found.frame) * 1_000_000L / rate;
        }
    }

    /** Para diagnóstico: quanto o áudio que toca agora está atrás do que acabou de chegar, e os buffers. */
    String describe(long nowNs) {
        long playing = currentPtsUs(nowNs);
        int bytesPerMs = Math.max(1, sampleRate * bytesPerFrame / 1000);
        String latency = "?";
        try {
            latency = String.valueOf(AudioTrack.class.getMethod("getLatency").invoke(track));
        } catch (Exception ignored) {
        }
        return "audio: atras da chegada=" + (playing == Long.MIN_VALUE ? "?" : (lastReceivedPtsUs - playing) / 1000)
                + "ms fila=" + queuedBytes.get() / bytesPerMs + "ms buffer=" + bufferBytes / bytesPerMs
                + "ms latenciaTrack=" + latency + "ms falhas=" + lastUnderruns;
    }

    synchronized void stop() {
        playing = false;
        if (thread != null) {
            thread.interrupt();
            try {
                thread.join(500);
            } catch (InterruptedException ignored) {
            }
            thread = null;
        }
        if (track != null) {
            try {
                track.stop();
            } catch (IllegalStateException ignored) {
            }
            track.release();
            track = null;
        }
        queue.clear();
        queuedBytes.set(0);
    }
}
