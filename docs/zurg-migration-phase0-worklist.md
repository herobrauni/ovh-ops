# Phase 0 worklist — reconciling the missing content

Generated **2026-10-01** against the live cluster (worktree `zurg-migration`).

Method: each entry present in the old symlink farm (`/aio/symlinks/...`, read via
`media-debug`) but absent from the `__magic__` trees (read via `zurg-debug`) was
searched in zurg's library with `zurg_library_search` using an **RE2 regex** built
from the title tokens. A plain `query` is a literal substring match and misses
dotted release names, so it is useless here (`Pulp Fiction` → 0 hits;
`(?i)pulp[._ -]+fiction` → 3).

## Verdicts

- **RECOVER** (49) — a library release matches title + year at the tree's own
  resolution (1080p/720 for `plex_hd/*`, 2160p for `plex_4k/*`). This is the
  placement queue; the candidate is in the last column.
- **WRONG-RES** (25) — title + year exist, but only at the *other* resolution.
  This tree cannot be filled from the current library: re-grab or accept.
- **GONE** (30) — no library match at all. **All 18 `other` entries (F1 / MotoGP /
  Isle of Man TT) are here** — the sports grabs never made it into zurg. Let the
  \*arr re-grab after Phase 3, or accept the loss.
- **LOW-CONF** (4) — the match is title-only or looks like an unrelated bundle.
  Review by hand.

## Caveats before placing anything

- Many candidates are **German-dub** releases (`… German … DL 1080p …`). The old
  farm entry may have been a different release; the \*arr will parse whatever is
  placed, but language/quality will differ. Decide the per-tree policy first
  (accept German dubs, or re-grab).
- Resolution detection is heuristic (`2160p|4k|uhd|remux` vs `1080p|720p`); a
  release tagged both ways (`1080p UHD BluRay`) counts as HD.
- A candidate may already be placed in the *other* tree (e.g. the 4K copy in
  `plex_4k/movies`). Verify with `zurg_magic_placed_paths` before moving.
- The lists are regenerable with the appendix one-liner in `zurg-migration.md`.

## Counts

| Verdict | Count |
| --- | ---: |
| RECOVER | 49 |
| WRONG-RES | 25 |
| GONE | 30 |
| LOW-CONF | 4 |
| **Total** | **108** |

## Worklist

| Entry | Verdict | Lib matches | Best candidate |
| --- | --- | ---: | --- |

**plex_hd/shows** (1)

| `Great Barrier Reef with David Attenborough (2015) {tvdb-304953}` | LOW-CONF | 1 | `Great.Barrier.Reef.With.David.Attenborough.S01.1080p.BluRay.x264-GHOULS` |

**plex_hd/movies** (64)

| `A Bugs Life (1998)` | GONE | 0 | — |
| `Ant-Man and the Wasp (2018)` | WRONG-RES | 4 | `Ant-Man.and.the.Wasp.2018.GERMAN.DL.DV.2160p.WEB.H265-DMPD` |
| `Atlantis Milos Return (2003)` | GONE | 0 | — |
| `Avatar The Way of Water (2022)` | LOW-CONF | 1 | `Um.Actually.S10E07.Wingspan.Matterhorn.Bobsleds.Avatar.The.Way.of.Water.1080p.DR` |
| `Baby Driver (2017)` | RECOVER | 2 | `Baby.Driver.2017.German.DTSD.DL.1080p.BluRay.x264-MULTiPLEX` |
| `Back to the Future (1985)` | RECOVER | 6 | `Back.to.the.Future.1985.German.AC3D.DL.1080p.BluRay.x264-HDA` |
| `Barbie (2023)` | WRONG-RES | 2 | `Barbie.2023.Eng.Fre.Ger.Ita.Spa.Cat.Cze.Slo.Chi.Jpn.2160p.BluRay.Hybrid.Remux.DV` |
| `Encanto (2021)` | WRONG-RES | 1 | `Encanto.2021.GERMAN.DUBBED.DL.HDR.2160p.WEB.h265-TMSF` |
| `Exterritorial (2025)` | WRONG-RES | 1 | `Exterritorial.2025.German.EAC3.Atmos.2160p.NF.WEB.H265-WalterBishop` |
| `Fantastic Beasts The Crimes of Grindelwald (2018)` | RECOVER | 3 | `Fantastic.Beasts-.The.Crimes.of.Grindelwald.2018.German.DTS.DL.1080p.BluRay.x264` |
| `Fantastic Beasts The Secrets of Dumbledore (2022)` | RECOVER | 2 | `Fantastic.Beasts-.The.Secrets.of.Dumbledore.2022.German.EAC3.DL.1080p.BluRay.x26` |
| `Final Destination 2 (2003)` | LOW-CONF | 1 | `Final.Destination.2000.GERMAN.DL.1080p.BluRay.x264-TSCC` |
| `Final Destination 5 (2011)` | RECOVER | 5 | `Final.Destination.5.3D.2011.German.DL.1080p.BluRay.x264-MAJESTiC` |
| `Finding Nemo (2003)` | RECOVER | 2 | `Finding Nemo 2003 GERMAN DUBBED DL 1080p UHD BluRay HDR H265-TSCC` |
| `Free Willy (1993)` | GONE | 0 | — |
| `Guardians of the Galaxy (2014)` | RECOVER | 8 | `Guardians.of.the.Galaxy.2014.GERMAN.DL.1080p.WEB.H264.iNTERNAL-SunDry-FTP` |
| `Guardians of the Galaxy Vol. 3 (2023)` | RECOVER | 3 | `Guardians.of.the.Galaxy.Vol.3.2023.IMAX.German.EAC3D.DL.1080p.BluRay.x265-VECTOR` |
| `How to Train Your Dragon The Hidden World (2019)` | RECOVER | 2 | `How.to.Train.Your.Dragon-.The.Hidden.World.2019.German.TrueHD.Atmos.DTSHD.DL.108` |
| `Inception (2010)` | RECOVER | 13 | `Inception.2010.German.DTSD.DL.1080p.BluRay.x264-VECTOR` |
| `Incredibles 2 (2018)` | WRONG-RES | 3 | `Incredibles.2.2018.GERMAN.DL.DV.2160p.WEB.H265-DMPD` |
| `Iron Man 3 (2013)` | RECOVER | 3 | `Iron.Man.3.2013.German.DTS.DL.1080p.BluRay.x264-MULTiPLEX` |
| `John Wick Chapter 3 Parabellum (2019)` | WRONG-RES | 1 | `John.Wick.Chapter.3.Parabellum.2019.PROPER.UHD.BluRay.2160p.TrueHD.Atmos.7.1.DV.` |
| `Jurassic Park III (2001)` | RECOVER | 2 | `Jurassic.Park.III.2001.German.EAC3.DL.1080p.UHD.BluRay.HDR.x265-VECTOR` |
| `Jurassic World (2015)` | RECOVER | 10 | `Jurassic.World.2015.German.EAC3.DL.1080p.BluRay.x265-VECTOR` |
| `Kal Ho Naa Ho (2003)` | RECOVER | 1 | `Kal.Ho.Naa.Ho.2003.German.720p.WebHD.h264.iNTERNAL-DUNGHiLL` |
| `Kingsman The Golden Circle (2017)` | RECOVER | 2 | `Kingsman.The.Golden.Circle.2017.German.AC3.1080p.BluRay.x265-FUNXDTV` |
| `Mad Max Beyond Thunderdome (1985)` | WRONG-RES | 1 | `Mad Max Beyond Thunderdome 1985 UHD BluRay 2160p TrueHD Atmos 7 1 DV HEVC HYBRID` |
| `Mission Impossible (1996)` | RECOVER | 21 | `Mission-.Impossible.1996.German.AC3.DL.1080p.BluRay.x264-VECTOR` |
| `Monsters Inc. (2001)` | GONE | 0 | — |
| `One Hundred and One Dalmatians (1961)` | RECOVER | 1 | `One.Hundred.and.One.Dalmatians.1961.German.DTS.DL.1080p.BluRay.x264-LeetHD` |
| `Paddington (2014)` | WRONG-RES | 5 | `Paddington.2014.2160p.UHD.Blu-ray.Remux.DV.HDR.HEVC.TrueHD.Atmos.7.1-CiNEPHiLES` |
| `Pirates of the Caribbean On Stranger Tides (2011)` | RECOVER | 3 | `Pirates.of.the.Caribbean-.On.Stranger.Tides.2011.German.EAC3.DL.1080p.UHD.BluRay` |
| `Pulp Fiction (1994)` | RECOVER | 3 | `Pulp.Fiction.1994.Special.Edition.German.DTS.DL.1080p.BluRay.x264-VECTOR` |
| `Smile (2022)` | RECOVER | 9 | `Smile.2022.German.EAC3.DL.1080p.WEB.x265-VECTOR` |
| `Song of the Sea (2014)` | GONE | 0 | — |
| `Star Wars Episode I The Phantom Menace (1999)` | RECOVER | 2 | `Star.Wars-.Episode.I.-.The.Phantom.Menace.1999.GERMAN.DL.1080p.HDR.UHD.BluRay.x2` |
| `Star Wars Episode III Revenge of the Sith (2005)` | WRONG-RES | 1 | `Star.Wars-.Episode.III.-.Revenge.of.the.Sith.Revenge.of.the.Sith.2005.Eng.Fre.Ge` |
| `Star Wars The Force Awakens (2015)` | RECOVER | 2 | `Star.Wars.The.Force.Awakens.Episode.VII.2015.MULTI.1080p.DSNP.WEB-DL.DDP5.1.x264` |
| `Star Wars The Last Jedi (2017)` | WRONG-RES | 1 | `Star.Wars-.The.Last.Jedi.2017.Eng.Fre.Ger.Ita.Spa.2160p.BluRay.Remux.DV.HDR.HEVC` |
| `Star Wars The Rise of Skywalker (2019)` | RECOVER | 2 | `Star.Wars.The.Rise.of.Skywalker.Episode.IX.2019.MULTI.1080p.DSNP.WEB-DL.DDP5.1.x` |
| `Stitch! The Movie (2003)` | GONE | 0 | — |
| `The Bad Guys (2022)` | RECOVER | 3 | `The.Bad.Guys.2022.German.EAC3.DL.1080p.BluRay.x265-VECTOR` |
| `The Conjuring (2013)` | RECOVER | 8 | `The.Conjuring.2013.1080p.BluRay.DTS.x264-DON` |
| `The Conjuring The Devil Made Me Do It (2021)` | WRONG-RES | 1 | `The.Conjuring-.The.Devil.Made.Me.Do.It.2021.German.DL.2160p.HDR.AMZN.WEB.H265-Ze` |
| `The Dark Knight Rises (2012)` | RECOVER | 3 | `The.Dark.Knight.Rises.2012.GERMAN.DL.1080p.HDR.UHD.BluRay.x265-TSCC` |
| `The Family Plan (2023)` | WRONG-RES | 3 | `The Family Plan 2023 UHD WEB-DL 2160p HEVC DV HDR10Plus EAC3 5 1 Atmos DL Remux-` |
| `The Hunger Games The Ballad of Songbirds and Snakes (2023)` | GONE | 0 | — |
| `The Ice Road (2021)` | RECOVER | 2 | `The.Ice.Road.2021.German.EAC3.DL.1080p.BluRay.x265-VECTOR` |
| `The Jungle Book (2016)` | RECOVER | 3 | `The.Jungle.Book.2016.German.DTS.DL.1080p.BluRay.x264-VECTOR` |
| `The Karate Kid Part III (1989)` | RECOVER | 2 | `The.Karate.Kid.Part.III.1989.REMASTERED.GERMAN.DL.1080p.BluRay.x264-MOGLi` |
| `The Lion King (1994)` | WRONG-RES | 4 | `The.Lion.King.1994.UHD.BluRay.2160p.TrueHD.Atmos.7.1.DV.HEVC.HYBRID.REMUX-FraMeS` |
| `The Lion King (2019)` | LOW-CONF | 4 | `Mufasa-.The.Lion.King.2024.German.DL.HDR.2160p.WEB.h265-W4K` |
| `The Little Mermaid II Return to the Sea (2000)` | GONE | 0 | — |
| `The Lost World Jurassic Park (1997)` | RECOVER | 2 | `The.Lost.World-.Jurassic.Park.1997.German.EAC3.DL.1080p.UHD.BluRay.HDR.x265-VECT` |
| `The Truman Show (1998)` | WRONG-RES | 1 | `The.Truman.Show.1998.2160p.BluRay.Remux.DV.HDR10HYBRID.TrueHD.7.1.Atmos.HEVC` |
| `The Wolf of Wall Street (2013)` | RECOVER | 2 | `The.Wolf.of.Wall.Street.2013.German.DTS.DL.1080p.BluRay.x264-VECTOR` |
| `Thor Ragnarok (2017)` | WRONG-RES | 1 | `Thor-.Ragnarok.2017.UHD.BluRay.2160p.TrueHD.Atmos.7.1.DV.HEVC.HYBRID.REMUX-FraMe` |
| `Tom Clancys Jack Ryan Ghost War (2026)` | GONE | 0 | — |
| `Tony Hawk Until the Wheels Fall Off (2022)` | RECOVER | 1 | `Tony.Hawk.Until.the.Wheels.Fall.Off.2022.GERMAN.DL.DOKU.1080p.WEB.H264-TSCC` |
| `Toy Story 4 (2019)` | WRONG-RES | 1 | `Toy.Story.4.2019.GERMAN.DL.DV.2160p.WEB.H265.REPACK-DMPD` |
| `Tron (1982)` | RECOVER | 13 | `Tron.1982.German.DTS.DL.1080p.BluRay.x264-RB` |
| `Wish (2023)` | RECOVER | 3 | `Wish.2023.German.DL.EAC3.1080p.WEB.H264-ZeroTwo` |
| `Wreck-It Ralph (2012)` | RECOVER | 2 | `Wreck-It.Ralph.2012.German.DTS.DL.1080p.BluRay.x264-MULTiPLEX` |
| `xXx (2002)` | RECOVER | 5 | `xXx.2002.Remastered.German.DL.1080p.BluRay.x264-CONTRiBUTiON` |

**plex_4k/movies** (25)

| `Aladdin (1992) {tmdb-812}` | RECOVER | 6 | `Aladdin.1992.UHD.US.BluRay.2160p.HEVC.DV.HDR.DTSHR.DL.Remux-TvR` |
| `Ant-Man and the Wasp (2018) {tmdb-363088}` | RECOVER | 4 | `Ant-Man.and.the.Wasp.2018.GERMAN.DL.DV.2160p.WEB.H265-DMPD` |
| `Avengers Endgame (2019) {tmdb-299534}` | RECOVER | 4 | `Avengers.Endgame.2019.German.EAC3.DL.2160p.UHD.BluRay.HDR.HEVC.Remux-NIMA4K` |
| `Bridget Joness Diary (2001) {tmdb-634}` | GONE | 0 | — |
| `Death of a Unicorn (2025) {tmdb-1153714}` | WRONG-RES | 1 | `Death.of.a.Unicorn.2025.German.DL.1080p.WEB.H264-ZeroTwo` |
| `Deep Blue (2003) {tmdb-11019}` | WRONG-RES | 4 | `Deep.Blue.2003.PROPER.1080p.BluRay.x264-LCHD-AsRequested` |
| `Den of Thieves (2018) {tmdb-449443}` | WRONG-RES | 3 | `Den of Thieves Duology-2018-2025-1080p BluRay x265 HEVC 10Bit DDP5.1-UKBandit` |
| `Dune (2021) {tmdb-438631}` | WRONG-RES | 2 | `Dune 2021 German EAC3 DL 1080p BluRay x265-VECTOR` |
| `Dune Part Two (2024) {tmdb-693134}` | WRONG-RES | 1 | `Dune.Part.Two.2024.German.DL.TrueHD.Atmos.1080p.BluRay.x264-ZeroTwo` |
| `Fantastic Beasts and Where to Find Them (2016) {tmdb-259316}` | RECOVER | 5 | `Fantastic.Beasts.and.Where.to.Find.Them.2016.German.UHDBD.2160p.DV.HDR10.HEVC.Tr` |
| `Hercules (1997) {tmdb-11970}` | WRONG-RES | 2 | `Hercules.1997.720p.BluRay.x264-CtrlHD-Rakuv02` |
| `John Wick (2014) {tmdb-245891}` | RECOVER | 8 | `John.Wick.2014.German.US.UHDBD.2160p.DV.HDR10.HEVC.DTSHD.DL.Remux-pmHD` |
| `Logan (2017) {tmdb-263115}` | RECOVER | 3 | `Logan.2017.German.UHDBD.2160p.DV.HDR10.HEVC.DTS.DL.Remux-pmHD` |
| `Mad Max (1979) {tmdb-9659}` | RECOVER | 10 | `Mad.Max.1979.German.US.UHDBD.2160p.DV.HDR10.HEVC.AC3.DL.Remux-pmHD` |
| `Mad Max Fury Road (2015) {tmdb-76341}` | WRONG-RES | 1 | `Mad.Max.Fury.Road.2015.1080p.BluRay.DD.Atmos.7.1.x264-LoRD` |
| `Mission Impossible Ghost Protocol (2011) {tmdb-56292}` | WRONG-RES | 1 | `Mission-.Impossible.-.Ghost.Protocol.2011.German.AC3.DL.1080p.BluRay.x264-VECTOR` |
| `One Battle After Another (2025) {tmdb-1054867}` | RECOVER | 4 | `One.Battle.After.Another.2025.UHD.WEB-DL.2160p.HEVC.DV.HDR10Plus.TrueHD.7.1.Atmo` |
| `Pirates of the Caribbean The Curse of the Black Pearl (2003) {tmdb-22}` | RECOVER | 3 | `Pirates.of.the.Caribbean-.The.Curse.of.the.Black.Pearl.2003.German.UHDBD.2160p.D` |
| `Roofman (2025) {tmdb-1242419}` | GONE | 0 | — |
| `Soul (2020) {tmdb-508442}` | RECOVER | 6 | `Soul.2020.German.EAC3D.DL.2160p.UHD.BluRay.HDR.HEVC.Remux.Repack-NIMA4K` |
| `The Fantastic 4 First Steps (2025) {tmdb-617126}` | RECOVER | 8 | `The.Fantastic.4.First.Steps.-.The.Fantastic.Four.First.Steps.2025.German.EAC3.DL` |
| `The Hobbit An Unexpected Journey (2012) {tmdb-49051}` | WRONG-RES | 1 | `The.Hobbit-.An.Unexpected.Journey.2012.GERMAN.eac3.1080p.WEB.h265-FritzBox` |
| `The Hobbit The Desolation of Smaug (2013) {tmdb-57158}` | GONE | 0 | — |
| `The Little Mermaid (1989) {tmdb-10144}` | RECOVER | 5 | `The.Little.Mermaid.1989.German.DL.EAC3.2160p.DV.HDR.DSNP.WEB.H265-ZeroTwo` |
| `Together (2025) {tmdb-1242011}` | RECOVER | 3 | `Together.2025.German.US.UHDBD.2160p.DV.HDR10Plus.HEVC.DTSHD.DL.Remux-pmHD` |

**other** (18)

| `Formula1.2026.Canadian.Grand.Prix.Qualifying.1080p.AHDTV.x264-DARKSPORT` | GONE | 0 | — |
| `Formula1.2026.Canadian.Grand.Prix.Sprint.Race.1080p.AHDTV.x264-DARKSPORT` | GONE | 0 | — |
| `Formula1.S2026E32.Canada.Sprint.Race.1080p.ANTP.WEB-DL.AAC2.0.H.264-playWEB` | GONE | 0 | — |
| `Isle.of.Man.TT.2026x01.Qualifying.Review.ITV4HD.1080p` | GONE | 0 | — |
| `Isle.of.Man.TT.2026x01.Qualifying.Review.ITV4HD.4K` | GONE | 0 | — |
| `Isle.of.Man.TT.2026x01.Qualifying.Review.ITV4HD.SD` | GONE | 0 | — |
| `Isle.of.Man.TT.2026x02.Racing.Postponed.ITV4HD.1080p` | GONE | 0 | — |
| `Isle.of.Man.TT.2026x02.Racing.Postponed.ITV4HD.4K` | GONE | 0 | — |
| `Isle.of.Man.TT.2026x02.Racing.Postponed.ITV4HD.SD` | GONE | 0 | — |
| `Isle.of.Man.TT.2026x03.RST.Superbike.TT.ITV4HD.1080p` | GONE | 0 | — |
| `Isle.of.Man.TT.2026x03.RST.Superbike.TT.ITV4HD.4K` | GONE | 0 | — |
| `Isle.of.Man.TT.2026x03.RST.Superbike.TT.ITV4HD.SD` | GONE | 0 | — |
| `Isle.of.Man.TT.2026x04.Monster.Energy.Supersport.TT.ITV4HD.1080p` | GONE | 0 | — |
| `Isle.of.Man.TT.2026x04.Monster.Energy.Supersport.TT.ITV4HD.4K` | GONE | 0 | — |
| `Isle.of.Man.TT.2026x04.Monster.Energy.Supersport.TT.ITV4HD.SD` | GONE | 0 | — |
| `MotoGP.2026.Hungary.1080p.WEB.h264-VERUM` | GONE | 0 | — |
| `MotoGP.2026.Hungary.Sprint.Race.1080p.WEB.h264-BILLIE` | GONE | 0 | — |
| `MotoGP.2026.Italy.1080p.WEB.h264-VERUM` | GONE | 0 | — |
