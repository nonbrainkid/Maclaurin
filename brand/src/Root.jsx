/* ─────────────────────────────────────────────────────────────────────────
 *  Оформление проекта: аватар, шапка X, баннер YouTube.
 *
 *  Палитра и типографика те же, что в web/styles.css (тёмная тема): бумага —
 *  тушь — охра, моноширинный для чисел, ни градиентов, ни свечения.
 *
 *  Общий графический мотив — частичные суммы ряда, подходящие к пунктиру e и
 *  не достающие до него. Это буквально тезис проекта, а не абстрактный узор.
 * ───────────────────────────────────────────────────────────────────────── */

import React from 'react';
import {AbsoluteFill, Composition} from 'remotion';

/* Токены — копия тёмной темы сайта. */
const C = {
  paper:  '#0b0c0e',
  ink:    '#e9eaec',
  ink2:   '#9aa0a9',
  ink3:   '#6d737c',
  line:   '#212429',
  line2:  '#343941',
  accent: '#dc9a63'
};

const MONO = 'Consolas, "SF Mono", Menlo, "Liberation Mono", monospace';
const SANS = 'system-ui, "Segoe UI", Roboto, Arial, sans-serif';

/** Частичные суммы ряда e = Σ 1/n!: 1, 2, 2.5, 2.666…, 2.708… */
function partialSums(count) {
  const out = [];
  let sum = 0;
  let fact = 1;
  for (let k = 0; k < count; k++) {
    if (k > 0) fact *= k;
    sum += 1 / fact;
    out.push(sum);
  }
  return out;
}

/**
 * Столбцы частичных сумм и пунктир на уровне e. Ни один столбец пунктира не
 * касается — частичная сумма строго меньше суммы ряда. Тот же факт, что
 * держит потолок множителя стейкинга.
 */
const Converge = ({w, h, bars = 10, opacity = 1, label = true}) => {
  const values = partialSums(bars);
  const top = h * 0.14;            // уровень e
  const step = w / bars;
  const barW = step * 0.46;

  return (
    <svg width={w} height={h} style={{opacity, display: 'block'}}>
      {values.map((v, i) => {
        const barH = (v / Math.E) * (h - top);
        return (
          <rect
            key={i}
            x={i * step + (step - barW) / 2}
            y={h - barH}
            width={barW}
            height={barH}
            fill={i === values.length - 1 ? C.accent : C.line2}
          />
        );
      })}
      <line x1={0} y1={top} x2={w} y2={top} stroke={C.accent} strokeWidth={Math.max(2, h / 160)} strokeDasharray={`${h / 26} ${h / 26}`} />
      {label ? (
        <text x={w} y={top - h * 0.045} textAnchor="end" fill={C.accent} fontFamily={MONO} fontSize={h * 0.1}>e</text>
      ) : null}
    </svg>
  );
};

/* ── аватар 1:1 ─────────────────────────────────────────────────────────── *
   Главный элемент — одна крупная глифа «e»: только она читается на 32 px в
   ленте. Остальное работает на крупных размерах и не мешает на мелких. */

const Avatar = () => (
  <AbsoluteFill style={{background: C.paper, alignItems: 'center', justifyContent: 'center'}}>
    {/* Кольцо круглое, а не скруглённый квадрат: X, Telegram и YouTube режут
        аватар по кругу — у квадратной рамки срезало бы углы. */}
    <div style={{position: 'absolute', inset: 46, border: `3px solid ${C.line2}`, borderRadius: '50%'}} />
    <div style={{display: 'flex', flexDirection: 'column', alignItems: 'center'}}>
      <div style={{fontFamily: MONO, fontSize: 74, color: C.accent, letterSpacing: 4}}>Σ 1/n!</div>
      {/* lineHeight меньше единицы убирает пустой бокс над и под глифом:
          иначе «e» тонет в воздухе и на 32 px читается как точка. */}
      <div style={{fontFamily: MONO, fontSize: 520, color: C.ink, lineHeight: 0.76, marginTop: 34, marginBottom: 38}}>e</div>
      <div style={{fontFamily: MONO, fontSize: 56, color: C.ink3, letterSpacing: 14, paddingLeft: 14}}>MACLRN</div>
    </div>
  </AbsoluteFill>
);

/* ── шапка X, 1500 × 500 (3:1) ──────────────────────────────────────────── *
   Аватар профиля перекрывает нижний левый угол, поэтому слева ниже y ≈ 320
   ничего значимого нет, а график уведён вправо. */

const XBanner = () => (
  <AbsoluteFill style={{background: C.paper}}>
    <div style={{position: 'absolute', right: 74, top: 54, fontFamily: MONO, fontSize: 21, color: C.ink3, letterSpacing: 2}}>
      Robinhood Chain · chain 4663
    </div>

    <div style={{position: 'absolute', right: 74, top: 128, width: 470}}>
      <Converge w={470} h={272} bars={10} opacity={0.95} />
    </div>

    <div style={{position: 'absolute', left: 104, top: 66, width: 800}}>
      <div style={{fontFamily: MONO, fontSize: 23, color: C.accent, letterSpacing: 9}}>Σ 1/n! · MACLRN</div>
      <div style={{fontFamily: SANS, fontSize: 62, fontWeight: 600, color: C.ink, letterSpacing: -1.8, lineHeight: 1.14, marginTop: 24}}>
        Supply is <span style={{fontFamily: MONO, color: C.accent}}>e</span>.<br />
        Emission is <span style={{fontFamily: MONO, color: C.accent}}>1/n!</span>.
      </div>
      <div style={{height: 1, background: C.line, width: 520, marginTop: 26}} />
      <div style={{fontFamily: MONO, fontSize: 20, color: C.ink2, letterSpacing: 1, marginTop: 16}}>
        no mint · no owner · no proxy
      </div>
    </div>
  </AbsoluteFill>
);

/* ── баннер YouTube, 2560 × 1440 ────────────────────────────────────────── *
   Гарантированно видимая на всех устройствах область — центральные
   1546 × 423. Всё, что должно читаться на телефоне, лежит внутри неё;
   график вынесен наружу и появляется только на широких экранах. */

const SAFE_W = 1546;
const SAFE_H = 423;

const YouTubeBanner = () => (
  <AbsoluteFill style={{background: C.paper}}>
    {/* Восемь столбцов, а не четырнадцать: после восьмого разница уже
        неразличима глазом и ряд превращается в ровный забор — подъём,
        ради которого график и нужен, пропадает. */}
    <div style={{position: 'absolute', left: 0, right: 0, bottom: 108, display: 'flex', justifyContent: 'center'}}>
      <Converge w={2280} h={330} bars={8} opacity={0.45} label={false} />
    </div>

    <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
      <div
        style={{
          width: SAFE_W,
          height: SAFE_H,
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center'
        }}
      >
        <div style={{fontFamily: MONO, fontSize: 34, color: C.accent, letterSpacing: 16}}>Σ 1/n!</div>
        <div style={{fontFamily: SANS, fontSize: 116, fontWeight: 600, color: C.ink, letterSpacing: -3.5, lineHeight: 1.06, marginTop: 22}}>
          Maclaurin Series
        </div>
        <div style={{fontFamily: MONO, fontSize: 40, color: C.ink2, marginTop: 20, letterSpacing: 0.5}}>
          Supply is <span style={{color: C.accent}}>e</span>. Emission is <span style={{color: C.accent}}>1/n!</span>.
        </div>
        <div style={{height: 1, background: C.line2, width: 700, marginTop: 30}} />
        <div style={{fontFamily: MONO, fontSize: 27, color: C.ink3, marginTop: 22, letterSpacing: 2}}>
          MACLRN · Robinhood Chain · @MaclaurinRHC
        </div>
      </div>
    </AbsoluteFill>
  </AbsoluteFill>
);

/* Статичные картинки: одна композиция — один кадр. */
export const RemotionRoot = () => (
  <>
    <Composition id="Avatar" component={Avatar} durationInFrames={1} fps={1} width={1024} height={1024} />
    <Composition id="XBanner" component={XBanner} durationInFrames={1} fps={1} width={1500} height={500} />
    <Composition id="YouTubeBanner" component={YouTubeBanner} durationInFrames={1} fps={1} width={2560} height={1440} />
  </>
);
