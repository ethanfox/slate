let orbMetalTail = #"""
float glsChromaticMetalPhase(
    metal::float2 p,
    float t,
    constant Uniforms& u
) {
    float angle = u.metalAngle * 0.01745329252;
    float scale = metal::max(u.metalScale, 0.05);
    float stretch = metal::mix(0.48, 1.58, metal::clamp(u.metalStretch, 0.0, 1.0));
    metal::float2 q = glsRotate(p / scale, angle);
    q = metal::float2(q.x / stretch, q.y * stretch);
    float cycle = t * 0.46 + u.metalPhase * 6.28318530718;
    float evolution = metal::clamp(u.metalEvolution, 0.0, 2.0);
    q.x += metal::sin(q.y * 1.86 - cycle) * 0.095 * evolution;
    q.x += metal::sin((q.x + q.y) * 1.28 + cycle * 2.0 + 1.4) * 0.045 * evolution;
    q.y += metal::sin(q.x * 1.52 + cycle + 0.8) * 0.07 * evolution;
    float repeats = metal::max(u.bandDensity, 1.0);
    return q.x * repeats * 2.18
         + metal::sin(q.y * (1.3 + repeats * 0.26) - cycle) * 0.56 * evolution
         + metal::sin((q.x - q.y) * 1.34 + cycle * 2.0 + 1.7) * 0.27 * evolution
         + metal::sin((q.x * 0.72 + q.y) * 2.1 - cycle * 3.0 + 0.35) * 0.11 * evolution
         + metal::sin(cycle) * 0.1
         + metal::sin(cycle * 3.0 + 0.7) * 0.035
         + cycle
         + u.metalOffset * 6.28318530718;
}

float glsChromaticMetalTone(
    float phase,
    constant Uniforms& u
) {
    float wave = 0.5 + 0.5 * metal::cos(phase);
    float roughness = metal::clamp(u.metalRoughness, 0.0, 1.0);
    float depth = metal::clamp(u.metalDepth, 0.0, 1.0);
    float edge = 0.025 + roughness * 0.18;
    float broadReflection = metal::smoothstep(0.5 - edge, 0.5 + edge, wave);
    float hardReflection = metal::pow(wave, metal::mix(13.0, 4.0, roughness));
    float blackFold = metal::pow(1.0 - wave, metal::mix(9.0, 3.0, roughness));
    float body = metal::mix(wave, broadReflection, 0.2 + depth * 0.3);
    return metal::clamp(0.018 + body * (0.46 + depth * 0.12)
                        + hardReflection * (0.3 + depth * 0.42)
                        - blackFold * (0.07 + depth * 0.11), 0.0, 1.0);
}

metal::float3 glsChromaticMetalSample(
    metal::float2 p,
    float t,
    constant Uniforms& u
) {
    float phase = glsChromaticMetalPhase(p, t, u);
    float angle = u.metalAngle * 0.01745329252;
    metal::float2 brushP = glsRotate(p / metal::max(u.metalScale, 0.05), angle);
    float brushed = metal::sin(brushP.y * 146.0
                               + metal::sin(brushP.x * 11.0) * 0.58)
                  + 0.48 * metal::sin(brushP.y * 317.0 - brushP.x * 5.0);
    float brushAmount = 0.004 + metal::clamp(u.metalRoughness, 0.0, 1.0) * 0.014;
    float tone = metal::clamp(glsChromaticMetalTone(phase, u)
                              + brushed * brushAmount, 0.0, 1.0);
    return lqRamp(tone, u.colorD.xyz, u.colorB.xyz, u.colorC.xyz, u.colorA.xyz, u);
}

metal::float3 glsChromaticMetalFluid(
    metal::float2 p,
    float t,
    constant Uniforms& u
) {
    float angle = u.metalAngle * 0.01745329252;
    metal::float2 splitDirection = glsRotate(metal::float2(0.0, 1.0), angle);
    metal::float2 split = splitDirection * u.chromaticShift * 0.045;
    metal::float3 redSample = glsChromaticMetalSample(p + split, t, u);
    metal::float3 neutral = glsChromaticMetalSample(p, t, u);
    metal::float3 blueSample = glsChromaticMetalSample(p - split, t, u);
    metal::float3 optical = metal::float3(redSample.x, neutral.y, blueSample.z);
    float fringe = metal::clamp(metal::length(optical - neutral) * 4.0, 0.0, 1.0);
    metal::float3 color = metal::mix(neutral, optical,
        metal::clamp(u.chromaticShift * (0.72 + fringe * 0.28), 0.0, 1.0));
    float centerTone = glsChromaticMetalTone(glsChromaticMetalPhase(p, t, u), u);
    float glint = metal::pow(centerTone,
        metal::mix(12.0, 5.0, metal::clamp(u.metalRoughness, 0.0, 1.0)));
    color = metal::mix(color, u.highlightColor.xyz,
        glint * metal::clamp(u.metalDepth, 0.0, 1.0) * 0.06);
    float radial2 = metal::clamp(metal::dot(p, p), 0.0, 1.0);
    metal::float3 normal = metal::normalize(metal::float3(
        p, metal::sqrt(metal::max(1.0 - radial2, 0.0))));
    float roughness = metal::clamp(u.metalRoughness, 0.0, 1.0);
    float depth = metal::clamp(u.metalDepth, 0.0, 1.0);
    float key = metal::pow(metal::max(metal::dot(normal,
        metal::normalize(metal::float3(-0.48, 0.62, 0.62))), 0.0),
        metal::mix(7.0, 3.0, roughness));
    float fill = metal::pow(metal::max(metal::dot(normal,
        metal::normalize(metal::float3(0.7, -0.34, 0.63))), 0.0),
        metal::mix(10.0, 4.0, roughness));
    float limb = 1.0 - normal.z;
    float fresnel = metal::pow(limb, 3.0);
    float rim = metal::pow(limb, 10.0);
    color *= 0.86 + normal.z * 0.14;
    color = metal::mix(color, u.highlightColor.xyz, key * (0.05 + depth * 0.13));
    color = metal::mix(color, u.colorC.xyz, fill * (0.025 + depth * 0.07));
    color = metal::mix(color, u.colorD.xyz, fresnel * (0.12 + depth * 0.15));
    color = metal::mix(color, u.highlightColor.xyz, rim * (0.035 + depth * 0.055));
    return glsFinishPresetFluid(color, p, u);
}

metal::float3 glsOpalFluid(
    metal::float2 p_13,
    float t_10,
    constant Uniforms& u
) {
    float d = {};
    float a_2 = 0.0;
    int i_3 = 0;
    metal::float3 color_6 = {};
    float _e4 = u.zoom;
    metal::float2 q_8 = p_13 * (0.8 + (_e4 * 0.64));
    float _e12 = u.warp;
    float complexity = 0.76 + (_e12 * 0.085);
    d = -(t_10) * 0.42;
    uint2 loop_bound_3 = uint2(4294967295u);
    bool loop_init_3 = true;
    while(true) {
        if (metal::all(loop_bound_3 == uint2(0u))) { break; }
        loop_bound_3 -= uint2(loop_bound_3.y == 0u, 1u);
        if (!loop_init_3) {
            int _e48 = i_3;
            i_3 = as_type<int>(as_type<uint>(_e48) + as_type<uint>(1));
        }
        loop_init_3 = false;
        int _e25 = i_3;
        if (_e25 < 8) {
        } else {
            break;
        }
        {
            int _e28 = i_3;
            float fi_1 = static_cast<float>(_e28);
            float _e30 = a_2;
            float _e31 = d;
            float _e33 = a_2;
            a_2 = _e30 + metal::cos((fi_1 - _e31) - ((_e33 * q_8.x) * complexity));
            float _e40 = d;
            float _e44 = a_2;
            d = _e40 + metal::sin(((q_8.y * fi_1) * complexity) + _e44);
        }
    }
    float _e51 = d;
    d = _e51 + (t_10 * 0.42);
    float _e55 = d;
    float _e56 = a_2;
    metal::float2 c1_ = (metal::cos(q_8 * metal::float2(_e55, _e56)) * 0.6) + metal::float2(0.4);
    float _e65 = a_2;
    float _e66 = d;
    float c2_ = (metal::cos(_e65 + _e66) * 0.5) + 0.5;
    float _e76 = d;
    float _e77 = a_2;
    metal::float3 interference = metal::float3(0.5) + (0.5 * metal::cos(((metal::float3(c1_.x, c1_.y, c2_) * metal::cos(metal::float3(_e76, _e77, 2.5))) * 0.5) + metal::float3(0.5)));
    float tone = metal::fract(((((interference.x * 0.37) + (interference.y * 0.51)) + (interference.z * 0.73)) + (c1_.x * 0.22)) - (c1_.y * 0.15));
    metal::float4 _e115 = u.colorB;
    metal::float4 _e119 = u.colorC;
    metal::float4 _e123 = u.colorD;
    metal::float4 _e127 = u.colorA;
    metal::float3 _e129 = lqRamp(tone, _e115.xyz, _e119.xyz, _e123.xyz, _e127.xyz, u);
    color_6 = _e129;
    metal::float3 _e131 = color_6;
    metal::float4 _e134 = u.colorA;
    color_6 = metal::mix(_e131, _e134.xyz, 0.16 + (0.1 * interference.z));
    metal::float3 _e142 = color_6;
    metal::float3 _e145 = color_6;
    color_6 = _e142 / (metal::float3(1.0) + (_e145 * 0.16));
    metal::float3 _e150 = color_6;
    metal::float3 _e151 = glsFinishPresetFluid(_e150, p_13, u);
    return _e151;
}

metal::float3 glsFrostFluid(
    metal::float2 p_14,
    float t_11,
    constant Uniforms& u
) {
    metal::float2 q_4 = {};
    metal::float3 color_7 = {};
    float _e4 = u.zoom;
    q_4 = p_14 * (0.66 + (_e4 * 0.92));
    float _e13 = q_4.y;
    q_4.y = _e13 + (t_11 * 0.055);
    float _e19 = u.zoom;
    float blur = 0.011 + (0.006 * _e19);
    metal::float2 _e24 = q_4;
    metal::float2 _e32 = lqFbm((_e24 * 1.14) + metal::float2(t_11 * 0.055, 0.0), blur);
    metal::float2 _e34 = q_4;
    metal::float2 _e43 = lqFbm((_e34 * 1.14) + metal::float2(6.8, -(t_11) * 0.048), blur);
    metal::float2 warpField = metal::float2(_e32.x, _e43.x);
    metal::float2 _e46 = q_4;
    float _e52 = u.warp;
    metal::float2 warped = _e46 + ((warpField - metal::float2(0.5)) * (0.28 + (_e52 * 0.17)));
    metal::float2 _e70 = lqFbm((warped * 1.48) + metal::float2(t_11 * 0.032, -(t_11) * 0.02), blur * 1.48);
    metal::float2 _e81 = lqFbm((warped * 2.36) + metal::float2(3.1, -(t_11) * 0.024), blur * 2.36);
    float _e84 = u.sharp;
    float _e85 = lqRidgeS(_e81, _e84);
    float _e88 = lqStepS(_e70, 0.1, 0.9);
    float _e100 = u.ridgeAmt;
    float value_1 = metal::mix(_e88, metal::clamp((_e85 * 0.8) + (_e70.x * 0.46), 0.0, 1.0), _e100);
    metal::float4 _e104 = u.colorA;
    metal::float4 _e108 = u.colorB;
    metal::float4 _e112 = u.colorC;
    metal::float4 _e116 = u.colorD;
    metal::float3 _e118 = lqRamp(value_1, _e104.xyz, _e108.xyz, _e112.xyz, _e116.xyz, u);
    color_7 = _e118;
    metal::float3 _e120 = color_7;
    metal::float4 _e123 = u.colorA;
    color_7 = metal::mix(_e120, _e123.xyz, 0.08 * metal::smoothstep(0.62, 0.92, _e70.x));
    metal::float3 _e132 = color_7;
    metal::float3 _e133 = glsFinishPresetFluid(_e132, p_14, u);
    return _e133;
}

metal::float3 glsVoiceWaveFluid(
    metal::float2 p_15,
    float t_12,
    constant Uniforms& u
) {
    metal::float3 color_8 = {};
    float _e4 = u.zoom;
    float scale_3 = 0.76 + (_e4 * 0.34);
    metal::float2 q_9 = p_15 / metal::float2(scale_3);
    float rimEnvelope = metal::pow(metal::max(1.0 - (q_9.x * q_9.x), 0.0), 0.72);
    float drift_3 = t_12 * 0.82;
    float _e24 = u.warp;
    float amplitude_4 = 0.2 + (_e24 * 0.018);
    float mainY_2 = rimEnvelope * ((amplitude_4 * metal::sin((q_9.x * 1.48) + drift_3)) + (0.055 * metal::sin(((q_9.x * 3.2) - (drift_3 * 0.43)) + 1.1)));
    float distance = q_9.y - mainY_2;
    float _e52 = u.ridgeAmt;
    float width = 0.11 + ((1.0 - _e52) * 0.075);
    float membrane = metal::exp((-(distance) * distance) / metal::max(width * width, 0.001)) * rimEnvelope;
    float upperVeil = metal::exp((-(distance - 0.105) * (distance - 0.105)) / metal::max((width * width) * 2.4, 0.001)) * rimEnvelope;
    float lowerVeil = metal::exp((-(distance + 0.115) * (distance + 0.115)) / metal::max((width * width) * 2.8, 0.001)) * rimEnvelope;
    float crest = metal::exp((-(distance) * distance) / 0.0026) * rimEnvelope;
    float depth = metal::sqrt(metal::max(1.0 - metal::clamp(metal::dot(p_15, p_15), 0.0, 1.0), 0.0));
    metal::float4 _e112 = u.colorA;
    metal::float4 _e118 = u.colorD;
    color_8 = metal::mix(_e112.xyz * 0.7, _e118.xyz * 0.34, metal::smoothstep(-0.82, 0.82, q_9.y));
    metal::float3 _e128 = color_8;
    metal::float4 _e131 = u.colorB;
    color_8 = metal::mix(_e128, _e131.xyz, upperVeil * 0.7);
    metal::float3 _e136 = color_8;
    metal::float4 _e139 = u.colorC;
    color_8 = metal::mix(_e136, _e139.xyz, lowerVeil * 0.62);
    metal::float3 _e144 = color_8;
    metal::float4 _e147 = u.colorB;
    metal::float4 _e151 = u.colorC;
    color_8 = _e144 + ((metal::mix(_e147.xyz, _e151.xyz, 0.46) * membrane) * 0.34);
    metal::float3 _e159 = color_8;
    metal::float4 _e162 = u.highlightColor;
    color_8 = _e159 + ((_e162.xyz * crest) * 0.14);
    metal::float3 _e168 = color_8;
    color_8 = _e168 * (0.58 + (0.42 * depth));
    metal::float3 _e174 = color_8;
    metal::float3 _e175 = glsFinishPresetFluid(_e174, p_15, u);
    return _e175;
}

metal::float3 glsBlueDropFluid(
    metal::float2 p,
    float t,
    constant Uniforms& u
) {
    float depth = metal::sqrt(metal::max(1.0 - metal::clamp(metal::dot(p, p), 0.0, 1.0), 0.0));
    metal::float2 q = p * metal::mix(0.72, 1.0, depth * 0.62 + 0.38);
    q = glsRotate(q, -0.24 + 0.06 * metal::sin(t * 0.17));
    float scale = 1.0 + u.zoom * 1.12;
    float blur = 0.012 + 0.006 * u.zoom;
    metal::float2 driftA = lqFbm(q * 1.28 + metal::float2(t * 0.095, -t * 0.034), blur * 1.28);
    metal::float2 driftB = lqFbm(glsRotate(q, 1.08) * 1.62
                                 + metal::float2(-t * 0.042, t * 0.078), blur * 1.62);
    metal::float2 flowed = q + metal::float2(driftA.x - 0.5, driftB.x - 0.5)
                               * (0.24 + u.warp * 0.1);
    flowed.x += metal::sin(flowed.y * 2.15 + t * 0.24) * (0.035 + u.warp * 0.012);
    flowed.y += metal::sin(flowed.x * 1.38 - t * 0.18) * (0.045 + u.warp * 0.01);
    metal::float2 body = lqFbm(flowed * scale + metal::float2(t * 0.025, -t * 0.018), blur * scale);
    float marbleScale = 1.72 + u.zoom * 0.9;
    float marble = lqRidgeS(lqFbm(flowed * marbleScale
                                  + metal::float2(2.7, -t * 0.035), blur * marbleScale),
                            0.8 + u.sharp * 0.46);
    float value = metal::clamp(metal::mix(body.x, body.x * 0.62 + marble * 0.58, u.ridgeAmt), 0.0, 1.0);
    metal::float3 color = lqRamp(value, u.colorA.xyz, u.colorB.xyz, u.colorC.xyz, u.colorD.xyz, u);
    metal::float3 surface = metal::normalize(metal::float3(p.x, p.y, depth));
    metal::float3 direction = metal::normalize(metal::float3(-0.48, 0.62, 0.92));
    float light = metal::pow(metal::max(metal::dot(surface, direction), 0.0), 3.2);
    color = metal::mix(color, u.highlightColor.xyz, light * (0.035 + 0.05 * u.shade));
    color *= 0.74 + 0.26 * depth;
    return glsFinishPresetFluid(color, p, u);
}

metal::float3 glsVioletEmberFluid(
    metal::float2 p,
    float t,
    constant Uniforms& u
) {
    float scale = 1.08 + u.zoom * 1.18;
    float blur = 0.011 + 0.005 * u.zoom;
    float radius = metal::length(p);
    float twist = t * 0.055 + radius * (0.72 + u.warp * 0.11)
                  + 0.08 * metal::sin(t * 0.31 + radius * 4.0);
    metal::float2 q = glsRotate(p * scale, twist);
    metal::float2 low = lqFbm(q * 1.18 + metal::float2(t * 0.068, -t * 0.105), blur * 1.18);
    metal::float2 cross = lqFbm(glsRotate(q, -1.12) * 1.52
                                + metal::float2(-t * 0.094, t * 0.042)
                                + metal::float2(low.x * 1.35, -low.x * 0.72), blur * 1.52);
    metal::float2 warped = q + metal::float2(low.x - 0.5, cross.x - 0.5)
                              * (0.3 + u.warp * 0.12);
    metal::float2 melt = lqFbm(warped * 1.34
                               + metal::float2(cross.x * 1.48, low.x * 1.12), blur * 1.34);
    float veinScale = 2.05 + u.zoom * 0.72;
    float veins = lqRidgeS(lqFbm(warped * veinScale
                                 + metal::float2(-2.1, t * 0.052), blur * veinScale),
                           0.82 + u.sharp * 0.58);
    float heat = metal::smoothstep(0.18, 0.92,
                                   melt.x * (0.72 - u.ridgeAmt * 0.16)
                                   + veins * (0.32 + u.ridgeAmt * 0.5));
    metal::float3 color = lqRamp(heat, u.colorA.xyz, u.colorB.xyz, u.colorC.xyz, u.colorD.xyz, u);
    float pulse = 0.94 + 0.06 * metal::sin(t * 0.44 + melt.x * 5.0);
    color *= pulse;
    color = metal::mix(color, u.highlightColor.xyz, metal::pow(veins, 4.0) * 0.045);
    return glsFinishPresetFluid(color, p, u);
}

metal::float3 glsRefractiveBlobFluid(
    metal::float2 p,
    float t,
    constant Uniforms& u
) {
    float radial2 = metal::clamp(metal::dot(p, p), 0.0, 1.0);
    float depth = metal::sqrt(metal::max(1.0 - radial2, 0.0));
    float scale = 0.82 + u.zoom * 1.08;
    float blur = 0.012 + 0.005 * u.zoom;
    metal::float2 q = glsRotate(p * scale, 0.08 * metal::sin(t * 0.17));
    metal::float2 driftA = lqFbm(
        q * 1.16 + metal::float2(t * 0.052, -t * 0.078), blur * 1.16);
    metal::float2 driftB = lqFbm(
        glsRotate(q, 1.21) * 1.34 + metal::float2(-t * 0.064, t * 0.041),
        blur * 1.34);
    q += metal::float2(driftA.x - 0.5, driftB.x - 0.5)
       * (0.34 + u.warp * 0.105);

    metal::float2 body = lqFbm(
        q * 1.42 + metal::float2(driftB.x * 0.82, driftA.x * 0.66),
        blur * 1.42);
    float ribbonPhase = q.y * (2.2 + u.warp * 0.11)
                      + metal::sin(q.x * 1.72 - t * 0.19) * 0.92
                      + metal::sin((q.x + q.y) * 1.08 + t * 0.13) * 0.46;
    float ribbon = metal::pow(
        metal::clamp(1.0 - metal::abs(metal::sin(ribbonPhase)), 0.0, 1.0),
        0.82 + u.sharp * 0.23);
    float fold = lqRidgeS(
        lqFbm(q * 2.05 + metal::float2(2.8, -t * 0.037), blur * 2.05),
        0.9 + u.sharp * 0.32);
    float value = metal::clamp(
        body.x * 0.5 + driftA.x * 0.16
        + ribbon * (0.2 + u.ridgeAmt * 0.2)
        + fold * u.ridgeAmt * 0.18, 0.0, 1.0);

    metal::float3 color = lqRamp(
        value, u.colorA.xyz, u.colorB.xyz, u.colorC.xyz, u.colorD.xyz, u);
    float caustic = metal::pow(ribbon, 3.1) * (0.24 + 0.28 * u.ridgeAmt)
                  + metal::pow(fold, 4.2) * 0.08;
    color = metal::mix(color, u.colorD.xyz, metal::clamp(caustic, 0.0, 0.52));
    color *= 0.7 + depth * 0.3;
    float key = metal::pow(metal::max(metal::dot(
        metal::normalize(metal::float3(p, depth)),
        metal::normalize(metal::float3(-0.42, 0.58, 0.9))), 0.0), 4.0);
    color = metal::mix(color, u.highlightColor.xyz, key * 0.055);
    return glsFinishPresetFluid(color, p, u);
}

metal::float3 glsParticleRibbonFluid(
    metal::float2 p,
    float t,
    constant Uniforms& u
) {
    return metal::float3(0.0);
}

metal::float3 glsPresetFluid(
    metal::float2 p_16,
    int style,
    float t_13,
    constant Uniforms& u
) {
    if (style == 9) {
        metal::float3 _e5 = glsSiriFluid(p_16, t_13, u);
        return _e5;
    }
    if (style == 10) {
        metal::float3 _e8 = glsAuroraFluid(p_16, t_13, u);
        return _e8;
    }
    if (style == 11) {
        metal::float3 _e11 = glsPlasmaFluid(p_16, t_13, u);
        return _e11;
    }
    if (style == 12) {
        metal::float3 _e14 = glsChromeFluid(p_16, t_13, u);
        return _e14;
    }
    if (style == 13) {
        metal::float3 _e17 = glsOpalFluid(p_16, t_13, u);
        return _e17;
    }
    if (style == 14) {
        metal::float3 _e20 = glsSpectrumFluid(p_16, t_13, u);
        return _e20;
    }
    if (style == 15) {
        metal::float3 _e23 = glsFrostFluid(p_16, t_13, u);
        return _e23;
    }
    if (style == 19) {
        metal::float3 _e26 = glsVoiceWaveFluid(p_16, t_13, u);
        return _e26;
    }
    if (style == 20) {
        return glsBlueDropFluid(p_16, t_13, u);
    }
    if (style == 21) {
        return glsVioletEmberFluid(p_16, t_13, u);
    }
    if (style == 22) {
        return glsChromaticMetalFluid(p_16, t_13, u);
    }
    if (style == 23) {
        return glsRefractiveBlobFluid(p_16, t_13, u);
    }
    if (style == 24) {
        return glsParticleRibbonFluid(p_16, t_13, u);
    }
    metal::float3 _e27 = glsFrostFluid(p_16, t_13, u);
    return _e27;
}

metal::float3 glsFluid(
    metal::float2 fu,
    int md,
    float t_14,
    constant Uniforms& u
) {
    metal::float3 fcol = {};
    metal::float2 pp = {};
    float v_2 = {};
    float df = metal::length(fu);
    metal::float4 _e6 = u.colorA;
    metal::float3 cA_1 = _e6.xyz;
    metal::float4 _e10 = u.colorB;
    metal::float3 cB_1 = _e10.xyz;
    metal::float4 _e14 = u.colorC;
    metal::float3 cC_1 = _e14.xyz;
    metal::float4 _e18 = u.colorD;
    metal::float3 cD_1 = _e18.xyz;
    float _e24 = u.glassEnabled;
    float blurSigma = (_e24 > 0.5) ? GL_BSIG_GLASS : GL_BSIG_CLEAR;
    float _e30 = u.zoom;
    float sp = blurSigma * _e30;
    float sw = (sp * 1.1) * GL_KWA;
    if (md < 0) {
        float _e41 = u.zoom;
        pp = fu * _e41;
        float _e46 = pp.y;
        pp.y = _e46 + (t_14 * 0.05);
        metal::float2 _e50 = pp;
        metal::float2 _e58 = lqFbm((_e50 * 1.1) + metal::float2(0.0, t_14 * 0.09), sw);
        metal::float2 _e60 = pp;
        metal::float2 _e69 = lqFbm((_e60 * 1.1) + metal::float2(7.7, -(t_14) * 0.07), sw);
        metal::float2 w = metal::float2(_e58.x, _e69.x);
        metal::float2 _e72 = pp;
        float _e75 = u.warp;
        metal::float2 q_10 = _e72 + (_e75 * (w - metal::float2(0.5)));
        metal::float2 _e90 = lqFbm((q_10 * 1.5) + metal::float2(t_14 * 0.04, 0.0), sp * 1.5);
        metal::float2 _e98 = lqFbm((q_10 * 2.2) + metal::float2(3.1), sp * 2.2);
        float _e101 = u.sharp;
        float _e102 = lqRidgeS(_e98, _e101);
        float _e105 = lqStepS(_e90, 0.12, 0.88);
        float _e117 = u.ridgeAmt;
        float v_3 = metal::mix(_e105, metal::clamp((_e102 * 0.85) + (0.45 * _e90.x), 0.0, 1.0), _e117);
        metal::float3 _e119 = lqRamp(v_3, cA_1, cB_1, cC_1, cD_1, u);
        fcol = _e119;
    } else {
        float _e122 = u.zoom;
        metal::float2 pp_1 = fu * _e122;
        metal::float2 _e131 = lqFbm((pp_1 * 1.1) + metal::float2(0.0, t_14 * 0.09), sw);
        metal::float2 _e141 = lqFbm((pp_1 * 1.1) + metal::float2(7.7, -(t_14) * 0.07), sw);
        metal::float2 w_1 = metal::float2(_e131.x, _e141.x);
        float _e146 = u.warp;
        metal::float2 q_11 = pp_1 + (_e146 * (w_1 - metal::float2(0.5)));
        if (md == 0) {
            metal::float2 _e158 = lqFbm(q_11 * 2.2, sp * 2.2);
            float damp = metal::exp(((-18.0 * _e158.y) * _e158.y) - ((24.5 * sp) * sp));
            v_2 = 0.5 + ((0.5 * damp) * metal::sin(((q_11.x * 7.0) + (_e158.x * 6.0)) + (t_14 * 0.35)));
            float _e186 = v_2;
            metal::float2 _e195 = lqFbm((q_11 * 1.4) + metal::float2(t_14 * 0.03), sp * 1.4);
            v_2 = metal::mix(_e186, _e195.x, 0.25);
            float _e199 = v_2;
            metal::float3 _e200 = lqRamp(_e199, cA_1, cB_1, cC_1, cD_1, u);
            fcol = _e200;
        } else {
            if (md == 1) {
                metal::float2 _e212 = lqFbm((q_11 * 1.4) + metal::float2(t_14 * 0.06, 0.0), sp * 1.4);
                float _e215 = u.sharp;
                float _e216 = lqRidgeS(_e212, _e215);
                metal::float2 _e226 = lqFbm((q_11 * 1.7) - metal::float2(0.0, t_14 * 0.05), sp * 1.7);
                float _e229 = u.sharp;
                float _e230 = lqRidgeS(_e226, _e229);
                float v_4 = _e216 * _e230;
                metal::float3 _e234 = lqRamp(metal::pow(v_4, 0.7), cA_1, cB_1, cC_1, cD_1, u);
                fcol = _e234;
            } else {
                if (md == 6) {
                    metal::float2 _e247 = lqFbm((q_11 * 2.6) + metal::float2(t_14 * 0.025), sp * 2.6);
                    metal::float2 _e255 = lqFbm((q_11 * 1.3) + metal::float2(1.5 * _e247.x), sp * 1.3);
                    metal::float2 _e263 = lqFbm((q_11 * 2.1) + metal::float2(7.0), sp * 2.1);
                    float _e265 = lqRidgeS(_e263, 1.3);
                    float _e268 = lqStepS(_e255, 0.1, 0.9);
                    metal::float3 _e269 = lqRamp(_e268, cA_1, cB_1, cC_1, cD_1, u);
                    fcol = _e269;
                    metal::float3 _e270 = fcol;
                    fcol = _e270 * (1.0 - (0.18 * _e265));
                } else {
                    metal::float2 q2_ = q_11 + metal::float2(0.0, -(t_14) * 0.14);
                    metal::float2 _e294 = lqFbm((q2_ * 2.4) + metal::float2(0.0, -(t_14) * 0.05), sp * 2.4);
                    metal::float2 _e302 = lqFbm((q2_ * 1.6) + metal::float2(2.2 * _e294.x), sp * 1.6);
                    float _e304 = lqPowS(_e302, 1.5);
                    metal::float3 _e305 = lqRamp(_e304, cA_1, cB_1, cC_1, cD_1, u);
                    fcol = _e305;
                }
            }
        }
    }
    metal::float3 _e306 = fcol;
    metal::float4 _e309 = u.highlightColor;
    float _e313 = u.shade;
    fcol = metal::mix(_e306, _e309.xyz, (_e313 * 0.3) * metal::smoothstep(0.25, 1.25, metal::dot(fu, metal::float2(-0.32, 0.78))));
    metal::float3 _e325 = fcol;
    float _e328 = u.shade;
    fcol = _e325 * (1.0 - ((_e328 * 0.42) * metal::smoothstep(-0.05, 1.25, metal::dot(fu, metal::float2(0.45, -0.62)))));
    metal::float3 _e342 = fcol;
    float _e345 = u.shade;
    fcol = _e342 * (1.0 - ((_e345 * 0.3) * metal::smoothstep(0.72, 1.0, df)));
    metal::float3 _e355 = fcol;
    return metal::clamp(_e355, metal::float3(0.0), metal::float3(1.0));
}

metal::float3 glsOver(
    metal::float3 dst,
    metal::float3 src,
    float a_3
) {
    float k_5 = metal::clamp(a_3, 0.0, 1.0);
    return (src * k_5) + (dst * (1.0 - k_5));
}

float glsRefractionProfile(
    float t_15
) {
    float depth_1 = metal::clamp(t_15, 0.0, 1.0);
    float circular = metal::sqrt(metal::max(1.0 - ((1.0 - depth_1) * (1.0 - depth_1)), 0.0));
    return 1.0 - circular;
}

float glsHighlightLobe(
    metal::float2 normal,
    metal::float2 direction,
    float cut,
    float power
) {
    float angular = metal::clamp((metal::dot(normal, direction) - cut) / metal::max(1.0 - cut, 0.001), 0.0, 1.0);
    return metal::pow(angular, power);
}

int naga_f2i32(float value) {
    return static_cast<int>(metal::clamp(value, -2147483600.0, 2147483500.0));
}

metal::float2 glsContourWave(
    float angle_1,
    float t_16,
    constant Uniforms& u
) {
    float _e4 = u.style;
    int style_1 = naga_f2i32(_e4 + 0.5);
    if (style_1 == 19) {
        float wave_1 = (metal::sin((angle_1 * 2.0) + (t_16 * 0.27)) * 0.72) + (metal::sin(((angle_1 * 4.0) - (t_16 * 0.16)) + 2.1) * 0.28);
        float slope = (metal::cos((angle_1 * 2.0) + (t_16 * 0.27)) * 1.44) + (metal::cos(((angle_1 * 4.0) - (t_16 * 0.16)) + 2.1) * 1.12);
        return metal::float2(wave_1, slope);
    }
    float wave_2 = ((metal::sin((angle_1 * 3.0) + (t_16 * 0.62)) * 0.52) + (metal::sin(((angle_1 * 5.0) - (t_16 * 0.41)) + 1.7) * 0.31)) + (metal::sin(((angle_1 * 2.0) + (t_16 * 0.23)) + 3.1) * 0.17);
    float slope_1 = ((metal::cos((angle_1 * 3.0) + (t_16 * 0.62)) * 1.56) + (metal::cos(((angle_1 * 5.0) - (t_16 * 0.41)) + 1.7) * 1.55)) + (metal::cos(((angle_1 * 2.0) + (t_16 * 0.23)) + 3.1) * 0.34);
    return metal::float2(wave_2, slope_1);
}

float glsContourStrength(
    constant Uniforms& u
) {
    float _e2 = u.style;
    if (_e2 >= 18.5) {
        return 0.11;
    }
    float _e10 = u.style;
    return (_e10 >= 15.5) ? 0.16 : 0.09;
}

float glsContourScale(
    metal::float2 uv_1,
    float t_17,
    float amount,
    constant Uniforms& u
) {
    if (amount <= 0.0) {
        return 1.0;
    }
    metal::float2 _e9 = glsContourWave(metal::atan2(uv_1.y, uv_1.x), t_17, u);
    float _e13 = glsContourStrength(u);
    return 1.0 + ((metal::clamp(amount, 0.0, 1.0) * _e13) * _e9.x);
}

metal::float2 glsContourNormal(
    metal::float2 uv_2,
    float rad_1,
    float t_18,
    float amount_1,
    constant Uniforms& u
) {
    float distance_1 = metal::length(uv_2);
    if (distance_1 <= 0.0001) {
        return metal::float2(0.0);
    }
    metal::float2 radial = uv_2 / metal::float2(distance_1);
    metal::float2 _e14 = glsContourWave(metal::atan2(uv_2.y, uv_2.x), t_18, u);
    float _e18 = glsContourStrength(u);
    float slope_2 = (metal::clamp(amount_1, 0.0, 1.0) * _e18) * _e14.y;
    metal::float2 tangent = metal::float2(-(radial.y), radial.x);
    return metal::normalize(radial - (tangent * ((rad_1 * slope_2) / distance_1)));
}

metal::float2 glsRefractionNormal(
    metal::float2 base,
    metal::float2 p,
    float t,
    int style
) {
    if (style != 23) {
        return base;
    }
    metal::float2 tangent = metal::float2(-base.y, base.x);
    float a = lqFbm(
        p * 2.15 + metal::float2(t * 0.061, -t * 0.043), 0.018).x;
    float b = lqFbm(
        glsRotate(p, 1.37) * 2.55 + metal::float2(-t * 0.037, t * 0.052),
        0.021).x;
    float wave = (a - b) * 0.76
               + metal::sin(metal::atan2(p.y, p.x) * 3.0 + t * 0.21) * 0.08;
    return metal::normalize(base + tangent * wave);
}

metal::float4 orbGlassLiquidAnim(
    metal::float2 uv01_,
    constant Uniforms& u
) {
    metal::float2 fc = metal::float2(uv01_.x, 1.0 - uv01_.y) * u.size;
    metal::float2 uv = (2.0 * fc - u.size)
                     / metal::max(metal::min(u.size.x, u.size.y), 1.0);
    float rad = metal::max(u.radius, 0.05);
    float t = u.time * u.speed;
    int s = naga_f2i32(u.style + 0.5);
    bool emissionOnly = u.glassEnabled <= 0.5 && (s == 9 || s == 14 || s == 24);
    float contourRad = rad * glsContourScale(uv, t, u.contourDeform, u);

    if (metal::length(uv) > contourRad * (1.01 + mfEdgeD(u.edgeSoftness))) {
        metal::float3 halo = mfEdgeGlow(metal::float3(0.0), uv, metal::float2(0.0),
                                         contourRad, u.edgeSoftness, u.edgeGlow,
                                         u.glowColor.xyz);
        halo = metal::clamp(halo, metal::float3(0.0), metal::float3(1.0));
        float haloAlpha = metal::max(halo.x, metal::max(halo.y, halo.z));
        return metal::float4(halo, haloAlpha);
    }

    metal::float2 p = uv / contourRad;
    float pd = metal::length(p);
    metal::float2 fu = p / GL_FU;
    int md = -1;
    if (s == 1) { md = 1; }
    else if (s == 3 || s == 8) { md = 7; }
    else if (s == 5) { md = 6; }
    else if (s == 7) { md = 0; }

    float clearFa = 1.0 - metal::smoothstep(GL_CLEAR_EA, GL_CLEAR_EB, pd);
    metal::float2 contourNormal = glsContourNormal(uv, rad, t, u.contourDeform, u);
    metal::float2 normal = glsRefractionNormal(contourNormal, p, t, s);
    float edgeDepth = metal::max(1.0 - pd, 0.0);
    float refractionWidth = 0.015 + 0.95 * metal::clamp(u.shellMidAlpha, 0.0, 1.0);
    float refractionT = edgeDepth / metal::max(refractionWidth, 0.001);
    float refractionProfile = metal::pow(glsRefractionProfile(refractionT), 0.68);
    float refractionAmount = 1.6 * metal::clamp(u.glassOpacity, 0.0, 1.0)
                           * refractionProfile;
    metal::float2 refractedP = p - normal * refractionAmount;
    metal::float3 fcol = metal::float3(0.0);

    if (clearFa > 0.0) {
        if (s >= 9) {
            if (u.glassEnabled > 0.5) {
                float channelSplit = 0.14 * metal::clamp(u.gloss, 0.0, 2.0)
                                   * metal::clamp(u.glassOpacity, 0.0, 1.0)
                                   * refractionProfile;
                metal::float3 redSample = glsPresetFluid(refractedP - normal * channelSplit, s, t, u);
                metal::float3 greenSample = glsPresetFluid(refractedP, s, t, u);
                metal::float3 blueSample = glsPresetFluid(refractedP + normal * channelSplit, s, t, u);
                fcol = metal::float3(redSample.x, greenSample.y, blueSample.z);
            } else {
                fcol = glsPresetFluid(p, s, t, u);
            }
        } else {
            fcol = glsFluid(fu, md, t, u);
        }
    }

    float lum = metal::dot(fcol, metal::float3(0.213, 0.715, 0.072));
    metal::float3 clearSat = metal::clamp(
        metal::float3(lum) + (fcol - metal::float3(lum)) * 1.22,
        metal::float3(0.0), metal::float3(1.0));
    bool particleGlassOverlay = s == 24;
    metal::float3 col = particleGlassOverlay
        ? metal::float3(0.0)
        : glsOver(u.canvasColor.xyz, clearSat, 0.99 * clearFa);
    if (emissionOnly) {
        float signal = metal::max(clearSat.x, metal::max(clearSat.y, clearSat.z));
        float emissionCoverage = metal::smoothstep(0.025, 0.16, signal);
        col = clearSat * emissionCoverage;
    }

    if (u.glassEnabled > 0.5) {
        float surfaceWidth = particleGlassOverlay
            ? 0.09 + 0.12 * metal::clamp(u.shellEdgeAlpha, 0.0, 1.0)
            : 0.026 + 0.055 * metal::clamp(u.shellEdgeAlpha, 0.0, 1.0);
        float surfaceBand = (1.0 - metal::smoothstep(0.0, surfaceWidth, edgeDepth)) * clearFa;
        float opticalRim = metal::pow(surfaceBand, particleGlassOverlay ? 1.3 : 1.8);
        float innerRimAlpha = !particleGlassOverlay
            ? opticalRim * u.glassOpacity * 0.45
            : opticalRim * u.glassOpacity * 0.14;
        col = glsOver(col, u.shellInner.xyz, innerRimAlpha);

        metal::float2 coolDirection = metal::normalize(metal::float2(0.84, 0.54));
        metal::float2 warmDirection = metal::normalize(metal::float2(-0.62, -0.78));
        float coolSplit = glsHighlightLobe(normal, coolDirection, -0.32, 1.8);
        float warmSplit = glsHighlightLobe(normal, warmDirection, -0.28, 2.0);
        float dispersion = opticalRim * metal::clamp(u.gloss, 0.0, 2.0)
                         * (0.8 + 0.8 * u.shellEdgeAlpha);
        col = glsOver(col, u.shellMid.xyz, dispersion * coolSplit);
        col = glsOver(col, u.shellEdge.xyz, dispersion * warmSplit);

        float edgeShadow = opticalRim * (0.015 + 0.15 * u.shellEdgeAlpha)
                         * (0.15 + 0.85 * metal::max(
                            metal::dot(normal, metal::float2(0.45, -0.89)), 0.0));
        col *= 1.0 - edgeShadow;

        metal::float2 keyDirection = metal::normalize(metal::float2(-0.68, 0.73));
        metal::float2 fillDirection = metal::normalize(metal::float2(0.74, -0.67));
        float key = opticalRim * glsHighlightLobe(normal, keyDirection, 0.2, 2.8)
                  * metal::clamp(u.sheen, 0.0, 2.0) * 1.4;
        float fill = opticalRim * glsHighlightLobe(normal, fillDirection, 0.4, 3.6)
                   * metal::clamp(u.sheen, 0.0, 2.0) * 1.0;
        col = glsOver(col, u.sheenColor.xyz, key);
        col = glsOver(col, u.specColor.xyz, fill);
    }

    float ballA = 1.0 - metal::smoothstep(
        0.99 - mfEdgeD(u.edgeSoftness),
        1.01 + mfEdgeD(u.edgeSoftness), pd);
    col = metal::clamp(col * metal::max(u.exposure, 0.0),
                       metal::float3(0.0), metal::float3(1.0)) * ballA;
    metal::float3 edged = mfEdgeGlow(col, uv, metal::float2(0.0), contourRad,
                                     u.edgeSoftness, u.edgeGlow, u.glowColor.xyz);
    metal::float3 finalColor = metal::clamp(
        edged, metal::float3(0.0), metal::float3(1.0));
    float emissionAlpha = metal::max(finalColor.x, metal::max(finalColor.y, finalColor.z));
    float sphereAlpha = metal::clamp(metal::max(ballA, emissionAlpha), 0.0, 1.0);
    float finalAlpha = (emissionOnly || particleGlassOverlay)
        ? emissionAlpha
        : sphereAlpha;
    return metal::float4(finalColor, finalAlpha);
}

struct vs_mainInput {
};
struct vs_mainOutput {
    metal::float4 pos [[position]];
    metal::float2 uv [[user(loc0), center_perspective]];
};
vertex vs_mainOutput vs_main(
  uint i [[vertex_id]]
) {
    type_7 p = type_7 {metal::float2(-1.0, -1.0), metal::float2(3.0, -1.0), metal::float2(-1.0, 3.0)};
    VOut out = {};
    metal::float2 _e15 = uint(i) < 3 ? p.inner[i] : DefaultConstructible();
    out.pos = metal::float4(_e15, 0.0, 1.0);
    metal::float2 _e20 = uint(i) < 3 ? p.inner[i] : DefaultConstructible();
    metal::float2 uv01_1 = (_e20 + metal::float2(1.0)) * 0.5;
    out.uv = metal::float2(uv01_1.x, 1.0 - uv01_1.y);
    VOut _e32 = out;
    const auto _tmp = _e32;
    return vs_mainOutput { _tmp.pos, _tmp.uv };
}

struct fs_mainInput {
    metal::float2 uv [[user(loc0), center_perspective]];
};
struct fs_mainOutput {
    metal::float4 member_1 [[color(0)]];
};
fragment fs_mainOutput fs_main(
  fs_mainInput varyings_1 [[stage_in]]
, metal::float4 pos [[position]]
, constant Uniforms& u [[buffer(0)]]
) {
    const VOut in = { pos, varyings_1.uv };
    metal::float4 _e2 = orbGlassLiquidAnim(in.uv, u);
    metal::float2 _e12 = u.size;
    metal::float2 fc_1 = metal::float2(in.uv.x, 1.0 - in.uv.y) * _e12;
    metal::float2 _e18 = u.size;
    float _e23 = u.size.x;
    float _e27 = u.size.y;
    metal::float2 uv_4 = ((2.0 * fc_1) - _e18) / metal::float2(metal::max(metal::min(_e23, _e27), 1.0));
    float _e35 = u.radius;
    float rad_3 = metal::max(_e35, 0.05);
    float _e40 = u.time;
    float _e43 = u.speed;
    float t_20 = _e40 * _e43;
    float _e47 = u.contourDeform;
    float _e48 = glsContourScale(uv_4, t_20, _e47, u);
    float contourRad_1 = rad_3 * _e48;
    metal::float2 _e76 = u.size;
    metal::float2 _e80 = u.size;
    metal::float2 q_12 = ((2.0 * fc_1) - _e76) / _e80;
    float fitEnd = 1.0;
    float fitFeather = 2.0 / metal::max(metal::min(u.size.x, u.size.y), 1.0);
    float fitStart = metal::min(metal::mix(contourRad_1, fitEnd, 0.5), fitEnd - fitFeather);
    float fit = 1.0 - metal::smoothstep(fitStart, fitEnd, metal::max(metal::abs(q_12.x), metal::abs(q_12.y)));
    return fs_mainOutput { metal::float4(_e2.xyz * fit, _e2.w * fit) };
}

constant uint PR_U_SEGMENTS = 384;
constant uint PR_V_SEGMENTS = 96;
constant uint PR_PARTICLES_PER_LAYER = PR_U_SEGMENTS * PR_V_SEGMENTS;

float prHash(float value) {
    return metal::fract(metal::sin(value * 12.9898 + 78.233) * 43758.5453);
}

metal::float3 prRotateX(metal::float3 p, float angle) {
    float c = metal::cos(angle);
    float s = metal::sin(angle);
    return metal::float3(p.x, c * p.y - s * p.z, s * p.y + c * p.z);
}

metal::float3 prRotateY(metal::float3 p, float angle) {
    float c = metal::cos(angle);
    float s = metal::sin(angle);
    return metal::float3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
}

metal::float3 prCurve(
    float theta,
    float layer,
    float phase,
    constant Uniforms& u
) {
    float local = theta + layer * 0.11;
    float foldPhase = 2.0 * local + phase * (0.72 + layer * 0.025);
    float fold = metal::clamp(u.ribbonFold, 0.0, 1.2);
    float radial = 0.4 + (0.085 + fold * 0.04) * metal::cos(foldPhase);
    float orbit = local + phase * 0.13
                + metal::sin(local - phase * 0.22 + layer) * fold * 0.13;
    float vertical = (0.235 + fold * 0.085) * metal::sin(foldPhase)
                   + 0.055 * metal::sin(local * 3.0 - phase * 0.46 + layer * 0.7);
    return metal::float3(radial * metal::cos(orbit), vertical, radial * metal::sin(orbit));
}

metal::float3 prPalette(float valueIn, constant Uniforms& u) {
    float value = metal::fract(valueIn) * 4.0;
    if (value < 1.0) return metal::mix(u.colorA.xyz, u.colorB.xyz, value);
    if (value < 2.0) return metal::mix(u.colorB.xyz, u.colorC.xyz, value - 1.0);
    if (value < 3.0) return metal::mix(u.colorC.xyz, u.colorD.xyz, value - 2.0);
    return metal::mix(u.colorD.xyz, u.colorA.xyz, value - 3.0);
}

struct ribbon_vs_mainOutput {
    metal::float4 pos [[position]];
    metal::float2 local [[user(loc0), center_no_perspective]];
    metal::float3 color [[user(loc1), center_perspective]];
    float opacity [[user(loc2), center_perspective]];
};

vertex ribbon_vs_mainOutput ribbon_vs_main(
    uint vertexIndex [[vertex_id]],
    uint instanceIndex [[instance_id]],
    constant Uniforms& u [[buffer(0)]]
) {
    const metal::float2 corners[6] = {
        metal::float2(-1.0, -1.0), metal::float2(1.0, -1.0),
        metal::float2(-1.0, 1.0), metal::float2(-1.0, 1.0),
        metal::float2(1.0, -1.0), metal::float2(1.0, 1.0)
    };
    uint layerIndex = instanceIndex / PR_PARTICLES_PER_LAYER;
    uint particleIndex = instanceIndex % PR_PARTICLES_PER_LAYER;
    uint uIndex = particleIndex / PR_V_SEGMENTS;
    uint vIndex = particleIndex % PR_V_SEGMENTS;
    float layer = float(layerIndex);
    float random = prHash(float(instanceIndex));
    bool activeLayer = layer < metal::floor(metal::clamp(u.ribbonCount, 2.0, 6.0) + 0.5);

    float uCoord = (float(uIndex) + prHash(float(instanceIndex) + 11.0) * 0.56)
                 / float(PR_U_SEGMENTS);
    float vCoord = (float(vIndex) + prHash(float(instanceIndex) + 29.0) * 0.46)
                 / float(PR_V_SEGMENTS);
    float strip = vCoord * 2.0 - 1.0;
    float t = u.time * u.speed;
    float phase = t * 0.48;
    float arc = metal::fract(uCoord + layer * 0.211 - phase * 0.019);
    float arcLength = 0.76 + 0.055 * metal::sin(t * 0.23 + layer * 1.71);
    float arcPosition = arc / arcLength;
    float arcEnvelope = metal::smoothstep(0.0, 0.075, arcPosition)
                      * (1.0 - metal::smoothstep(0.88, 1.0, arcPosition));
    bool active = activeLayer
               && arc <= arcLength
               && random <= metal::clamp(u.particleDensity, 0.2, 1.0);
    float theta = uCoord * 6.28318530718;
    metal::float3 center = prCurve(theta, layer, phase, u);
    metal::float3 ahead = prCurve(theta + 0.006, layer, phase, u);
    metal::float3 tangent = metal::normalize(ahead - center);
    metal::float3 radial = metal::normalize(center + metal::float3(0.001, 0.013, 0.007));
    metal::float3 side = metal::normalize(metal::cross(tangent, radial));
    metal::float3 surfaceNormal = metal::normalize(metal::cross(side, tangent));
    float twist = theta * (0.72 + u.ribbonTwist * 0.58)
                + phase * 0.74 + layer * 1.17;
    metal::float3 ribbonDirection = metal::normalize(
        side * metal::cos(twist) + surfaceNormal * metal::sin(twist));
    float widthEnvelope = (0.72 + 0.28
        * metal::pow(metal::sin(theta * 1.5 + phase + layer), 2.0))
        * metal::mix(0.42, 1.0, metal::sqrt(metal::max(arcEnvelope, 0.0)));
    metal::float3 position = center
        + ribbonDirection * strip * u.ribbonWidth * 0.5 * widthEnvelope;

    float pulse = metal::sin(t * 0.73 + layer * 1.71)
                + 0.44 * metal::sin(t * 1.17 + layer * 0.83 + 1.2);
    position *= 1.0 + u.ribbonBreath * pulse * 0.16;
    float layerCenter = layer
        - (metal::floor(metal::clamp(u.ribbonCount, 2.0, 6.0) + 0.5) - 1.0) * 0.5;
    position = prRotateY(
        position, layerCenter * 0.24 + metal::sin(t * 0.19 + layer * 1.3) * 0.055);
    position = prRotateX(
        position, layerCenter * 0.14 + metal::cos(t * 0.17 + layer * 0.9) * 0.04);
    position = prRotateY(position, t * 0.105 + metal::sin(t * 0.21) * 0.11);
    position = prRotateX(position, -0.2 + metal::sin(t * 0.16 + layer * 0.1) * 0.16);

    float minSize = metal::max(metal::min(u.size.x, u.size.y), 1.0);
    float depthScale = 0.88 + position.z * 0.16;
    metal::float2 orbPosition = position.xy * u.radius * 1.45 * depthScale;
    metal::float2 clip = metal::float2(
        orbPosition.x * minSize / metal::max(u.size.x, 1.0),
        orbPosition.y * minSize / metal::max(u.size.y, 1.0));
    float canvasParticleScale = metal::clamp(minSize / 640.0, 0.22, 1.0);
    float pointPixels = metal::max(0.6, u.particleSize)
                      * (1.5 + u.particleBloom * 2.5)
                      * (0.92 + position.z * 0.18)
                      * canvasParticleScale;
    metal::float2 corner = corners[vertexIndex];
    metal::float2 pointOffset = corner * pointPixels * 2.0
                              / metal::max(u.size, metal::float2(1.0));

    float colorPhase = uCoord * 0.32 + layer * 0.19 + phase * 0.025
                     + position.z * 0.08;
    float stripEdge = metal::smoothstep(0.58, 1.0, metal::abs(strip));
    float front = metal::clamp(0.78 + position.z * 0.54, 0.5, 1.24);
    float baseOpacity = metal::mix(0.025, 0.009,
        metal::clamp(u.shade / 1.5, 0.0, 1.0));

    ribbon_vs_mainOutput out;
    out.pos = active
        ? metal::float4(clip + pointOffset,
                        metal::clamp(0.5 - position.z * 0.12, 0.05, 0.95), 1.0)
        : metal::float4(2.0, 2.0, 1.0, 1.0);
    out.local = corner;
    out.color = metal::pow(
        metal::mix(prPalette(colorPhase, u), u.highlightColor.xyz, stripEdge * 0.56),
        metal::float3(0.72)) * front;
    out.opacity = active
        ? baseOpacity
            * (0.72 + stripEdge * 1.28)
            * arcEnvelope
            * metal::pow(canvasParticleScale, 1.35)
        : 0.0;
    return out;
}

struct ribbon_fs_mainOutput {
    metal::float4 color [[color(0)]];
};

fragment ribbon_fs_mainOutput ribbon_fs_main(
    ribbon_vs_mainOutput in [[stage_in]],
    constant Uniforms& u [[buffer(0)]]
) {
    float distanceSquared = metal::dot(in.local, in.local);
    if (distanceSquared > 1.0) metal::discard_fragment();
    float core = metal::exp(-distanceSquared * 4.8);
    float halo = metal::exp(-distanceSquared * 1.35);
    float bloom = metal::clamp(u.particleBloom, 0.0, 2.0);
    float intensity = in.opacity * (core * 1.9 + halo * bloom * 0.72)
                    * metal::max(u.exposure, 0.0);
    float glowMix = metal::clamp((halo - core * 0.45)
        * (0.18 + u.edgeGlow * 0.5), 0.0, 0.7);
    metal::float3 color = metal::mix(in.color, u.glowColor.xyz, glowMix);
    float alpha = metal::clamp(intensity, 0.0, 1.0);
    return ribbon_fs_mainOutput { metal::float4(color * alpha, alpha) };
}

metal::float2 prTextureUvFromOrb(
    metal::float2 p,
    float contourRad,
    constant Uniforms& u
) {
    float minSize = metal::max(metal::min(u.size.x, u.size.y), 1.0);
    metal::float2 fc = (p * contourRad * minSize + u.size) * 0.5;
    return metal::clamp(
        metal::float2(
            fc.x / metal::max(u.size.x, 1.0),
            1.0 - fc.y / metal::max(u.size.y, 1.0)),
        metal::float2(0.0),
        metal::float2(1.0));
}

struct ribbon_composite_fs_mainOutput {
    metal::float4 color [[color(0)]];
};

fragment ribbon_composite_fs_mainOutput ribbon_composite_fs_main(
    fs_mainInput in [[stage_in]],
    metal::float4 position [[position]],
    constant Uniforms& u [[buffer(0)]],
    metal::texture2d<float> ribbonTexture [[texture(0)]]
) {
    constexpr metal::sampler ribbonSampler(
        metal::coord::normalized,
        metal::address::clamp_to_edge,
        metal::filter::linear);
    metal::float4 direct = ribbonTexture.sample(ribbonSampler, in.uv);
    if (u.glassEnabled <= 0.5) {
        return ribbon_composite_fs_mainOutput { direct };
    }

    metal::float2 fc = metal::float2(in.uv.x, 1.0 - in.uv.y) * u.size;
    float minSize = metal::max(metal::min(u.size.x, u.size.y), 1.0);
    metal::float2 uv = (2.0 * fc - u.size) / minSize;
    float rad = metal::max(u.radius, 0.05);
    float t = u.time * u.speed;
    float contourRad = rad * glsContourScale(uv, t, u.contourDeform, u);
    metal::float4 shell = orbGlassLiquidAnim(in.uv, u);
    if (metal::length(uv) > contourRad * (1.01 + mfEdgeD(u.edgeSoftness))) {
        return ribbon_composite_fs_mainOutput { shell };
    }

    metal::float2 p = uv / contourRad;
    float pd = metal::length(p);
    float clearFa = 1.0 - metal::smoothstep(GL_CLEAR_EA, GL_CLEAR_EB, pd);
    metal::float2 normal = glsContourNormal(uv, rad, t, u.contourDeform, u);
    float edgeDepth = metal::max(1.0 - pd, 0.0);
    float refractionWidth = 0.015 + 0.95 * metal::clamp(u.shellMidAlpha, 0.0, 1.0);
    float refractionT = edgeDepth / metal::max(refractionWidth, 0.001);
    float refractionProfile = metal::pow(glsRefractionProfile(refractionT), 0.68);
    float refractionAmount = 1.6 * metal::clamp(u.glassOpacity, 0.0, 1.0)
                           * refractionProfile;
    metal::float2 refractedP = p - normal * refractionAmount;
    float channelSplit = 0.14 * metal::clamp(u.gloss, 0.0, 2.0)
                       * metal::clamp(u.glassOpacity, 0.0, 1.0)
                       * refractionProfile;
    metal::float4 redSample = ribbonTexture.sample(
        ribbonSampler,
        prTextureUvFromOrb(refractedP - normal * channelSplit, contourRad, u));
    metal::float4 greenSample = ribbonTexture.sample(
        ribbonSampler,
        prTextureUvFromOrb(refractedP, contourRad, u));
    metal::float4 blueSample = ribbonTexture.sample(
        ribbonSampler,
        prTextureUvFromOrb(refractedP + normal * channelSplit, contourRad, u));
    float refractedAlpha = metal::max(
        redSample.w,
        metal::max(greenSample.w, blueSample.w)) * clearFa;
    metal::float4 refracted = metal::float4(
        metal::float3(redSample.x, greenSample.y, blueSample.z) * clearFa,
        refractedAlpha);
    return ribbon_composite_fs_mainOutput {
        metal::float4(
            shell.xyz + refracted.xyz * (1.0 - shell.w),
            shell.w + refracted.w * (1.0 - shell.w))
    };
}

"""#
