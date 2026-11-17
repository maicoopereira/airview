package br.com.maico.projetartv;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Liga o serviço de controle quando a TV termina de iniciar (ou o app é atualizado). */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        ControlService.start(context);
    }
}
