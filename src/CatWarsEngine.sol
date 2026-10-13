// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title CAT WARS deterministic fight engine (reference port of engine.js / engine.rs)
/// @notice simulate(catA, catB, seed) MUST reproduce engine.js bit-for-bit, including the ORDER of RNG draws.
///         Verified against the 500 JS-generated vectors in test/CatWarsEngine.t.sol.
library CatWarsEngine {
    uint8 internal constant NUM_CATS = 8;
    int256 internal constant MAX_TURNS = 30;
    uint32 internal constant SKILL_USE_PCT = 70;

    struct Skill {
        int256 dmg;       // damage %, 100 = 1.0x; 0 = no damage
        int256 hits;      // 0 => 1
        int256 crit;      // crit chance %, 0 => 10
        bool pierce;      // ignore DEF
        int256 stun;      // stun chance %
        int256 lifesteal; // % of damage dealt healed
        int256 heal;      // % of max HP
        int256 shield;    // % damage reduction
        int256 buff;      // +% ATK
        int256 weaken;    // -% enemy ATK
        int256 curse;     // enemy miss chance %
        bool dodge;       // evade next attack
        int256 turns;     // effect duration
        int256 cd;        // cooldown
    }

    struct Cat { int256 hp; int256 atk; int256 def; int256 spd; Skill[3] skills; }

    struct Fighter {
        Cat cat;
        int256 hp;
        int256 max;
        int256[3] cds;
        int256 buffV; int256 buffT;     // effect active iff T > 0
        int256 weakV; int256 weakT;
        int256 shieldV; int256 shieldT;
        int256 curseV; int256 curseT;
        bool dodge;
        bool stunned;
        bool stunImmune;
    }

    /* ---------------- roster (index = cat id; never reorder, only append) ---------------- */

    function _s(int256 dmg, int256 cd) private pure returns (Skill memory k) { k.dmg = dmg; k.cd = cd; }

    function cat(uint8 id) internal pure returns (Cat memory c) {
        require(id < NUM_CATS, "bad cat");
        if (id == 0) { // TIGRIS
            c.hp = 260; c.atk = 39; c.def = 30; c.spd = 22;
            c.skills[0] = _s(160, 2);
            c.skills[1].weaken = 30; c.skills[1].turns = 2; c.skills[1].cd = 4;
            c.skills[2] = _s(55, 3); c.skills[2].hits = 3;
        } else if (id == 1) { // SHADOW
            c.hp = 220; c.atk = 43; c.def = 24; c.spd = 32;
            c.skills[0].dodge = true; c.skills[0].cd = 3;
            c.skills[1] = _s(135, 2); c.skills[1].crit = 45;
            c.skills[2].curse = 35; c.skills[2].turns = 2; c.skills[2].cd = 4;
        } else if (id == 2) { // MOCHI
            c.hp = 295; c.atk = 32; c.def = 40; c.spd = 12;
            c.skills[0] = _s(130, 3); c.skills[0].stun = 35;
            c.skills[1].heal = 22; c.skills[1].cd = 4;
            c.skills[2].shield = 40; c.skills[2].turns = 2; c.skills[2].cd = 4;
        } else if (id == 3) { // LEO
            c.hp = 290; c.atk = 41; c.def = 40; c.spd = 18;
            c.skills[0].buff = 35; c.skills[0].turns = 2; c.skills[0].cd = 4;
            c.skills[1] = _s(150, 2);
            c.skills[2].shield = 30; c.skills[2].heal = 8; c.skills[2].turns = 2; c.skills[2].cd = 4;
        } else if (id == 4) { // GLITCH
            c.hp = 240; c.atk = 43; c.def = 32; c.spd = 26;
            c.skills[0] = _s(40, 4); c.skills[0].stun = 60;
            c.skills[1] = _s(125, 2); c.skills[1].pierce = true;
            c.skills[2].buff = 25; c.skills[2].turns = 3; c.skills[2].cd = 5;
        } else if (id == 5) { // ZOOMIES
            c.hp = 220; c.atk = 38; c.def = 22; c.spd = 35;
            c.skills[0] = _s(40, 3); c.skills[0].hits = 4;
            c.skills[1] = _s(180, 3);
            c.skills[2].heal = 12; c.skills[2].buff = 20; c.skills[2].turns = 2; c.skills[2].cd = 4;
        } else if (id == 6) { // GRUMPY
            c.hp = 295; c.atk = 41; c.def = 44; c.spd = 17;
            c.skills[0].weaken = 25; c.skills[0].turns = 3; c.skills[0].cd = 4;
            c.skills[1] = _s(140, 2); c.skills[1].lifesteal = 60;
            c.skills[2].shield = 45; c.skills[2].turns = 1; c.skills[2].cd = 3;
        } else { // 7 NOVA
            c.hp = 220; c.atk = 38; c.def = 28; c.spd = 30;
            c.skills[0] = _s(180, 4);
            c.skills[1].dodge = true; c.skills[1].cd = 3;
            c.skills[2] = _s(70, 3); c.skills[2].stun = 40;
        }
    }

    /* ---------------- PRNG: xoshiro128**, state = bytes 0..15 of seed as 4 little-endian uint32 ---------------- */

    function _seed(bytes32 seed) private pure returns (uint32[4] memory s) {
        for (uint256 i = 0; i < 4; i++) {
            s[i] = uint32(uint8(seed[i * 4])) | (uint32(uint8(seed[i * 4 + 1])) << 8)
                 | (uint32(uint8(seed[i * 4 + 2])) << 16) | (uint32(uint8(seed[i * 4 + 3])) << 24);
        }
        if (s[0] | s[1] | s[2] | s[3] == 0) s[0] = 1;
    }

    function _rotl(uint32 x, uint32 k) private pure returns (uint32) { return (x << k) | (x >> (32 - k)); }

    function _next(uint32[4] memory s) private pure returns (uint32 result) {
        unchecked {
            result = _rotl(s[1] * 5, 7) * 9;
            uint32 t = s[1] << 9;
            s[2] ^= s[0]; s[3] ^= s[1]; s[1] ^= s[2]; s[0] ^= s[3];
            s[2] ^= t; s[3] = _rotl(s[3], 11);
        }
    }

    function _below(uint32[4] memory s, uint32 n) private pure returns (int256) { return int256(uint256(_next(s) % n)); }

    /* ---------------- fight ---------------- */

    function _fighter(uint8 id) private pure returns (Fighter memory f) {
        f.cat = cat(id); f.hp = f.cat.hp; f.max = f.cat.hp;
    }

    function _pick(Fighter memory me, uint32[4] memory rng) private pure returns (int256) {
        uint256[3] memory ready; uint256 n;
        for (uint256 i = 0; i < 3; i++) {
            Skill memory s = me.cat.skills[i];
            if (me.cds[i] > 0) continue;
            if (s.heal > 0 && s.dmg == 0 && me.hp * 100 > me.max * 70) continue;
            if (s.shield > 0 && me.shieldT > 0) continue;
            if (s.buff > 0 && s.heal == 0 && me.buffT > 0) continue;
            if (s.dodge && me.dodge) continue;
            ready[n++] = i;
        }
        if (n > 0 && _below(rng, 100) < int256(uint256(SKILL_USE_PCT))) return int256(ready[uint256(_below(rng, uint32(n)))]);
        return -1;
    }

    function _act(Fighter memory me, Fighter memory foe, uint32[4] memory rng) private pure {
        for (uint256 k = 0; k < 3; k++) if (me.cds[k] > 0) me.cds[k] -= 1;
        if (me.stunned) { me.stunned = false; me.stunImmune = true; return; }
        me.stunImmune = false;

        int256 idx = _pick(me, rng);
        Skill memory s;
        if (idx >= 0) { s = me.cat.skills[uint256(idx)]; me.cds[uint256(idx)] = s.cd; }
        else { s.dmg = 100; } // basic Scratch

        int256 heal;
        if (s.heal > 0) heal += me.max * s.heal / 100;
        if (s.shield > 0) { me.shieldV = s.shield; me.shieldT = s.turns; }
        if (s.buff > 0) { me.buffV = s.buff; me.buffT = s.turns; }
        if (s.dodge) me.dodge = true;
        if (s.weaken > 0) { foe.weakV = s.weaken; foe.weakT = s.turns; }
        if (s.curse > 0) { foe.curseV = s.curse; foe.curseT = s.turns; }

        if (s.dmg > 0) {
            if (foe.dodge) {
                foe.dodge = false;
            } else if (me.curseT > 0 && _below(rng, 100) < me.curseV) {
                // missed (bad luck)
            } else {
                int256 hits = s.hits > 0 ? s.hits : int256(1);
                int256 critPct = s.crit > 0 ? s.crit : int256(10);
                int256 atkPct = 100 + (me.buffT > 0 ? me.buffV : int256(0)) - (me.weakT > 0 ? me.weakV : int256(0));
                int256 def = s.pierce ? int256(0) : foe.cat.def;
                int256 total;
                for (int256 h = 0; h < hits; h++) {
                    int256 d = me.cat.atk * atkPct * s.dmg;
                    d = d * 100 / (100 + def);
                    d = d * (85 + _below(rng, 31)) / 100;
                    if (_below(rng, 100) < critPct) d = d * 175 / 100;
                    if (foe.shieldT > 0) d = d * (100 - foe.shieldV) / 100;
                    int256 dealt = d / 10000;
                    total += dealt > 1 ? dealt : int256(1);
                }
                foe.hp -= total;
                if (s.lifesteal > 0) heal += total * s.lifesteal / 100;
                if (s.stun > 0 && foe.hp > 0 && !foe.stunImmune && _below(rng, 100) < s.stun) foe.stunned = true;
            }
        }
        if (heal > 0) {
            int256 room = me.max - me.hp;
            me.hp += heal < room ? heal : room;
        }
    }

    function _tick(Fighter memory f) private pure {
        if (f.buffT > 0) f.buffT -= 1;
        if (f.weakT > 0) f.weakT -= 1;
        if (f.shieldT > 0) f.shieldT -= 1;
        if (f.curseT > 0) f.curseT -= 1;
    }

    /// @return winner 0 = catA, 1 = catB
    function simulate(uint8 catA, uint8 catB, bytes32 seed)
        internal pure returns (uint8 winner, uint8 turns, int256 hpA, int256 hpB)
    {
        uint32[4] memory rng = _seed(seed);
        Fighter memory a = _fighter(catA);
        Fighter memory b = _fighter(catB);

        int256 turn;
        while (a.hp > 0 && b.hp > 0 && turn < MAX_TURNS) {
            turn += 1;
            int256 i0 = a.cat.spd + _below(rng, 13);
            int256 i1 = b.cat.spd + _below(rng, 13);
            if (i0 >= i1) {
                _act(a, b, rng);
                if (a.hp > 0 && b.hp > 0) _act(b, a, rng);
            } else {
                _act(b, a, rng);
                if (a.hp > 0 && b.hp > 0) _act(a, b, rng);
            }
            _tick(a); _tick(b);
        }

        if (b.hp <= 0) winner = 0;
        else if (a.hp <= 0) winner = 1;
        else winner = a.hp * b.max >= b.hp * a.max ? 0 : 1;
        turns = uint8(uint256(turn));
        hpA = a.hp > 0 ? a.hp : int256(0);
        hpB = b.hp > 0 ? b.hp : int256(0);
    }
}
