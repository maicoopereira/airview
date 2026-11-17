package br.com.maico.projetartv;

import android.util.Base64;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.PublicKey;
import java.security.SecureRandom;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.X509EncodedKeySpec;
import java.util.Arrays;

import javax.crypto.Cipher;
import javax.crypto.KeyAgreement;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * Criptografia do AirView — o mesmo esquema de mac/Sources/ProjetarTV/Security.swift (mudanças nos dois).
 * Pareamento ECDH P-256 + HKDF-SHA256; comandos com HMAC-SHA256; transmissão em AES-256-GCM.
 */
final class Crypto {
    static final SecureRandom RANDOM = new SecureRandom();

    private Crypto() {
    }

    static byte[] hmac(byte[] key, String label, byte[]... parts) throws GeneralSecurityException {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(key, "HmacSHA256"));
        if (label != null) mac.update(label.getBytes(StandardCharsets.UTF_8));
        for (byte[] part : parts) mac.update(part);
        return mac.doFinal();
    }

    static byte[] random(int count) {
        byte[] bytes = new byte[count];
        RANDOM.nextBytes(bytes);
        return bytes;
    }

    static boolean equals(byte[] a, byte[] b) {
        return a != null && b != null && MessageDigest.isEqual(a, b);
    }

    static String b64(byte[] data) {
        return Base64.encodeToString(data, Base64.NO_WRAP);
    }

    static byte[] unb64(String text) {
        return Base64.decode(text, Base64.NO_WRAP);
    }

    // ----- Pareamento -----

    static KeyPair newKeyPair() throws GeneralSecurityException {
        KeyPairGenerator generator = KeyPairGenerator.getInstance("EC");
        generator.initialize(new ECGenParameterSpec("secp256r1"));
        return generator.generateKeyPair();
    }

    /** Chave de pareamento K = HKDF-SHA256(ECDH(privada, pública do Mac), "airview-pair-v1", "airview-key"). */
    static byte[] pairingKey(PrivateKey own, byte[] peerDer) throws GeneralSecurityException {
        PublicKey peer = KeyFactory.getInstance("EC").generatePublic(new X509EncodedKeySpec(peerDer));
        KeyAgreement agreement = KeyAgreement.getInstance("ECDH");
        agreement.init(own);
        agreement.doPhase(peer, true);
        byte[] shared = agreement.generateSecret();
        // HKDF (RFC 5869) com 32 bytes de saída = um bloco
        byte[] prk = hmac("airview-pair-v1".getBytes(StandardCharsets.UTF_8), null, shared);
        return hmac(prk, "airview-key", new byte[]{1});
    }

    /** Código de verificação ("123 456"), igual ao mostrado no Mac. */
    static String verificationCode(byte[] key) throws GeneralSecurityException {
        byte[] digest = hmac(key, "airview-sas");
        long value = ((digest[0] & 0xffL) << 24 | (digest[1] & 0xffL) << 16 | (digest[2] & 0xffL) << 8
                | (digest[3] & 0xffL)) % 1_000_000;
        String digits = String.format(java.util.Locale.ROOT, "%06d", value);
        return digits.substring(0, 3) + " " + digits.substring(3);
    }

    /** Abre o formato "combined" do CryptoKit: nonce (12) | texto cifrado | tag (16). */
    static byte[] openCombined(byte[] key, byte[] combined) throws GeneralSecurityException {
        if (combined.length < 28) throw new GeneralSecurityException("curto demais");
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"),
                new GCMParameterSpec(128, Arrays.copyOfRange(combined, 0, 12)));
        return cipher.doFinal(combined, 12, combined.length - 12);
    }

    /** Decifra as mensagens de uma conexão de transmissão (nonce = contador, como StreamCipher no Mac). */
    static final class StreamDecryptor {
        private final SecretKeySpec key;
        private final Cipher cipher;
        private long counter;

        StreamDecryptor(byte[] sessionKey, byte[] challenge) throws GeneralSecurityException {
            key = new SecretKeySpec(hmac(sessionKey, "airview-stream", challenge), "AES");
            cipher = Cipher.getInstance("AES/GCM/NoPadding");
        }

        /** Devolve o tamanho do texto decifrado, escrito em {@code out}. Falha se alguém alterou os dados. */
        int open(byte[] frame, int length, byte[] out) throws GeneralSecurityException {
            byte[] nonce = new byte[12];
            for (int i = 0; i < 8; i++) nonce[4 + i] = (byte) (counter >>> (56 - 8 * i));
            counter++;
            cipher.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, nonce));
            return cipher.doFinal(frame, 0, length, out, 0);
        }
    }
}
