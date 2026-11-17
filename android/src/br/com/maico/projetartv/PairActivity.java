package br.com.maico.projetartv;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Bundle;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.lang.ref.WeakReference;

/** Pede confirmação na TV para parear com um Mac: mostra o código e aceita com OK, recusa com Voltar. */
public class PairActivity extends Activity {
    private static WeakReference<PairActivity> current = new WeakReference<>(null);
    private ControlService.PairRequest request;

    static void closeIfOpen() {
        PairActivity activity = current.get();
        if (activity != null) activity.runOnUiThread(activity::finish);
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        request = ControlService.currentPairRequest();
        if (request == null) {
            finish();
            return;
        }
        current = new WeakReference<>(this);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        if (Build.VERSION.SDK_INT >= 27) {
            setTurnScreenOn(true);
            setShowWhenLocked(true);
        }

        FrameLayout root = new FrameLayout(this);
        root.setBackground(new GradientDrawable(GradientDrawable.Orientation.TL_BR,
                new int[]{0xFF38C8F8, 0xFF2F7BF5, 0xFF1747C8}));

        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setGravity(Gravity.CENTER);
        int padH = dp(64), padV = dp(40);
        card.setPadding(padH, padV, padH, padV);
        GradientDrawable glass = new GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM,
                new int[]{0x4DFFFFFF, 0x1AFFFFFF});
        glass.setCornerRadius(dp(36));
        glass.setStroke(dp(1.5f), 0x66FFFFFF);
        card.setBackground(glass);

        ImageView icon = new ImageView(this);
        icon.setImageResource(R.drawable.icon);
        card.addView(icon, new LinearLayout.LayoutParams(dp(88), dp(88)));
        card.addView(text(getString(R.string.parear_com, request.macName), 26, false, dp(20)));
        card.addView(text(request.code, 64, true, dp(12)));
        card.addView(text(getString(R.string.parear_instrucao), 20, false, dp(16)));

        root.addView(card, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER));
        setContentView(root);
    }

    private TextView text(String value, float sp, boolean bold, int topMargin) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextColor(Color.WHITE);
        view.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        view.setGravity(Gravity.CENTER);
        view.setTypeface(Typeface.create(bold ? "sans-serif-medium" : "sans-serif", Typeface.NORMAL));
        if (bold) view.setLetterSpacing(0.08f);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        params.topMargin = topMargin;
        view.setLayoutParams(params);
        return view;
    }

    private int dp(float value) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, getResources().getDisplayMetrics());
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_DPAD_CENTER || keyCode == KeyEvent.KEYCODE_ENTER) {
            answer(true);
            return true;
        }
        if (keyCode == KeyEvent.KEYCODE_BACK) {
            answer(false);
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    private void answer(boolean accepted) {
        if (request != null && request.answered.getCount() > 0) {
            request.accepted = accepted;
            request.answered.countDown();
        }
        finish();
    }

    @Override
    protected void onDestroy() {
        // Sair da tela sem responder conta como recusa.
        if (request != null && request.answered.getCount() > 0) request.answered.countDown();
        super.onDestroy();
    }
}
