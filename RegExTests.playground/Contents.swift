import UIKit


var rasenfunk = """
            <![CDATA[Kovac schafft das Wunder, die Eintracht feiert königlich, Leipzig steht vor einem Scherbenhaufen und Heidenheim zittert. Eva-Lotta Bohle und Karoline Kipper blicken auf die Saison aller Bundesligisten.
    <p><strong>Unsere Bankverbindung hat sich geändert. Ihr müsstet bitte JETZT eure Daueraufträge umstellen!</strong></p>
    <p>Das sind die neuen Daten:
    <br /><br />
    Empfänger: Rasenfunk GmbH<br />
    IBAN: DE77 1001 8000 0928 1695 47<br />
    BIC: FNOMDEB2<br />
    PLZ (für Auslandsüberweiser): 81539<br /><br /></p>
    <p>Wenn ihr mit uns über diese Änderung diskutieren wollt oder Fragen habt, findet ihr dazu einen <a href=\"https://mitmachen.rasenfunk.de/t/wichtig-kontoumstellung-again/6870\">Thread im Forum</a>.</p>
    <p>Wir besprechen den 34. Spieltag in der Bundesliga der Männer und ziehen für jeden Verein ein Saisonfazit. Vielen Dank, dass ihr mit eurer Unterstützung diese Sendung möglich gemacht habt! In dieser Folge danken wir: @NicDiek, Johnny, Schmi, Jan und Dennis.</p>
    <p><strong>Der Rasenfunk hat keine Paywall und ist werbe-, sponsorenfrei. Wir finanzieren uns ausschließlich über euch Hörerinnen und Hörer.</strong> Wer erfahren möchte, wie man supporten kann, erfahrt alles Nötige unter: <a href=\"https://rasenfunk.de/supportersclub\">https://rasenfunk.de/supportersclub</a></p>
    <p>Das sind unsere Gästinnen: </p>
    <ul>
    <li><strong>Karoline Kipper</strong> (freie Journalistin, <a href=\"https://twitter.com/kalorineki\">Twitter</a>, <a href=\"https://bsky.app/profile/kalorineki.bsky.social\">Bluesky</a>)</li>
    <li><strong>Eva-Lotta Bohle</strong> (<a href=\"https://art19.com/shows/11freunde\">11 Freunde täglich</a>, <a href=\"https://bsky.app/profile/evabohle.bsky.social\">Bluesky</a>)</li>
    </ul>
    <p>In dieser Reihenfolge geht es durch die Sendung:</p>
    <p>00:00:00 | Wir brauchen eure Meinung!<br />
    00:04:10 | VfL Bochum<br />
    00:16:01 | Holstein Kiel<br />
    00:29:31 | 1. FC Heidenheim<br />
    00:42:55 | TSG Hoffenheim<br />
    00:56:40 | FC St. Pauli<br />
    01:08:14 | 1. FC Union Berlin<br />
    01:22:58 | FC Augsburg<br />
    01:34:08 | VfL Wolfsburg<br />
    01:43:08 | Borussia Mönchengladbach<br />
    01:53:32 | VfB Stuttgart<br />
    02:08:38 | Werder Bremen<br />
    02:21:00 | RaBa Leipzig<br />
    02:32:15 | Feedbackschleife, Infos und Dank<br />
    02:35:01 | 1.FSV Mainz 05<br />
    02:47:58 | SC Freiburg<br />
    02:59:54 | Borussia Dortmund<br />
    03:13:49 | Eintracht Frankfurt<br />
    03:30:57 | Leverkusen<br />
    03:42:20 | FC Bayern<br />
    03:58:23 | Verabschiedung und Podcastempfehlungen<br />
    04:00:58 | Bitte unterstützt den Rasenfunk!<br /></p>
    <h3 id=\"hrerinnenumfrage\">Hörer:innenumfrage</h3>
    <ul>
    <li><a href=\"https://docs.google.com/forms/d/e/1FAIpQLSeW8hsk-XrYiuqeqLoiQRlZ8KoSm9PXX0L7LnfmhEkOofhrEw/viewform?usp=send_form\">Bitte mitmachen</a></li>
    </ul>
    <h3 id=\"rasenfunkuntersttzen\">Rasenfunk unterstützen!</h3>
    <ul>
    <li>Rasenfunk Supporters-Club: <a href=\"https://rasenfunk.de/supportersclub\">Hier könnt ihr uns unterstützen</a></li>
    <li>Mitmachen.rasenfunk.de: <a href=\"https://mitmachen.rasenfunk.de/\">Diskutiert mit im Forum!</a></li>
    </ul>
    <h3 id=\"awards\">Awards</h3>
    <ul>
    <li>VfL Bochum: Felix Passlack (MVP), Tom Krauß (Unsung Hero)</li>
    <li>Holstein Kiel: Shuto Machino (MVP), Thomas Dähne (Unsung Hero)</li>
    <li>1. FC Heidenheim: Patrick Mainka (MVP), Jan Schöppner (Unsung Hero)</li>
    <li>TSG Hoffenheim: Oliver Baumann (MVP), Anton Stach (Unsung Hero)</li>
    <li>FC St. Pauli: Jackson Irvine (MVP), Nikola Vasilj (Unsung Hero)</li>
    <li>1. FC Union: Benedict Hollerbach (MVP), Rest-Union (Unsung Hero)</li>
    <li>FC Augsburg: Finn Dahmen (MVP), Cedric Zesiger (Unsung Hero)</li>
    <li>VfL Wolfsburg: Mohammed Amoura (MVP), Kamil Grabara (Unsung Hero)</li>
    <li>Borussia Mönchengladbach: Tim Kleindienst (MVP), 
    Ko Itakura (Unsung Hero)</li>
    <li>VfB Stuttgart: Nick Woltemade (MVP), Maximilian Mittelstädt (Unsung Hero)</li>
    <li>Werder Bremen: Marco Friedl (MVP), Jens Stage (Unsung Hero)</li>
    <li>RaBa Leipzig: Benjamin Sesko (MVP), Peter Gulacsi (Unsung Hero)</li>
    <li>1. FSV Mainz 05: Nadiem Amiri (MVP), Stefan Bell (Unsung Hero)</li>
    <li>SC Freiburg: Ritsu Doan (MVP), Noah Atubolu (Unsung Hero)</li>
    <li>Borussia Dortmund: Serhou Guirassy (MVP), Julian Ryerson (Unsung Hero)</li>
    <li>Eintracht Frankfurt: Mario Götze (MVP), Arthur Theate (Unsung Hero)</li>
    <li>Leverkusen: Florian Wirtz (MVP), Granit Xhaka (Unsung Hero)</li>
    <li>FC Bayern: Michael Olisé (MVP), Konrad Laimer (Unsung Hero)</li>
    </ul>
    <h3 id=\"podcastempfehlungen\">Podcastempfehlungen</h3>
    <ul>
    <li><a href=\"https://fyyd.de/user/Horst724/curation/rasenfunk-empfehlungen?page=0\">Abonnierbare Liste aller Empfehlungen</a></li>
    </ul>
    <p>Vielen Dank an <strong>Julia Scholz</strong> (<a href=\"https://bsky.app/profile/nithiel.bsky.social\">Bluesky</a>), die Stimme des Rasenfunks!</p>
    <p><a rel=\"payment\" href=\"https://rasenfunk.de/supportersclub\">Unterstützt unsere Show</a></p>
    <p>Wer keine Sendung von uns verpassen möchte, kann uns auf diesen Social-Media-Kanälen folgen oder unseren Newsletter auf rasenfunk.de abonnieren:</p>
    <ul>
    <li><a href=\"https://bsky.app/profile/rasenfunk.social\">Bluesky</a></li>
    <li><a href=\"https://podcasts.social/@rasenfunk\">Mastodon</a></li>
    <li><a href=\"https://instagram.com/rasenfunk\">Instagram</a> </li>
    <li><a href=\"https://twitter.com/rasenfunk\">Twitter</a></li>
    <li><a href=\"https://facebook.com/rasenfunk\">Facebook</a></li>
    <li><a href=\"https://youtube.com/rasenfunk\">Youtube</a></li>
    </ul>]]>
    """

var laesterSchwester = "<p>Der Podcast über das Internet mit YouTuber Robin Blase &amp; Gästen aus der Internet-Welt. Hier diskutieren und lästern wir jeden Samstag über YouTube, das Internet, Social Media, Influencer*innen und was das Netz diese Woche so bewegt. Folgt uns auf <a href=\"https://www.instagram.com/laesterschwestern_podcast/\" rel=\"noopener noreferrer\" target=\"_blank\">Instagram</a> und diskutiert mit uns auf <a href=\"https://www.reddit.com/r/Laesterschwestern/\" rel=\"noopener noreferrer\" target=\"_blank\">Reddit</a>. Robin findet ihr auf <a href=\"https://www.youtube.com/@RobBubble\" rel=\"noopener noreferrer\" target=\"_blank\">YouTube</a>, <a href=\"https://www.instagram.com/robbubble/\" rel=\"noopener noreferrer\" target=\"_blank\">Instagram</a> und <a href=\"https://www.tiktok.com/@robbubble\" rel=\"noopener noreferrer\" target=\"_blank\">TikTok</a>.&nbsp;</p><br><p>Lisa findet ihr auf <a href=\"https://www.instagram.com/notstrongonlyaggressive/\" rel=\"noopener noreferrer\" target=\"_blank\">Instagram</a> und <a href=\"https://substack.com/@lisaludwig\" rel=\"noopener noreferrer\" target=\"_blank\">Substack</a>.</p><br><p><strong>Werbung:</strong></p><p><a href=\"https://zez.am/laesterschwestern_podcast\" rel=\"noopener noreferrer\" target=\"_blank\">Hier</a> findest du alle Infos und Rabatte unserer Werbepartner.</p><br><p><strong>Kapitel*</strong></p><ul><li>00:00:00 Hi Lisa!</li><li>00:02:16 Bibi hat was gesehen – und jetzt ist sie sehr traurig</li><li>00:21:53 ApoRed auf Zypern gesichtet?&nbsp;</li><li>00:31:11 Böhmermann vs. Clownswelt</li><li>00:50:08 Der horny Yellowstone-Account</li></ul><p><br></p><p>*Je nachdem, ob und wie lang Werbespots eingespielt werden, können sich die Kapitel danach um etwa zwei bis vier Minuten verschieben.</p><br><p><strong>Unsere Themen und Quellen:</strong></p><ul><li><a href=\"https://www.instagram.com/biancaheinicke/#\" rel=\"noopener noreferrer\" target=\"_blank\">@biancaheinicke auf IG</a></li><li><a href=\"https://www.bild.de/unterhaltung/stars-und-leute/bianca-bibi-heinicke-auf-instagram-habe-gerade-was-so-schlimmes-erfahren-682456d2a010824e498f2a26\" rel=\"noopener noreferrer\" target=\"_blank\">Bibi: „Habe gerade was so Schlimmes erfahren“ | Bild</a></li><li><a href=\"https://www.instagram.com/reel/DJkhpJnId2k/?utm_source=ig_web_copy_link\" rel=\"noopener noreferrer\" target=\"_blank\">@germaninsides auf Instagram</a></li><li><a href=\"https://www.youtube.com/watch?v=fsKouaaD7og\" rel=\"noopener noreferrer\" target=\"_blank\">Kellner? | @ApoRed auf YouTube</a></li><li><a href=\"https://x.com/wasbruda06069/status/1922403009964740986?s=46\" rel=\"noopener noreferrer\" target=\"_blank\">@wasbruda06069 auf X</a></li><li><a href=\"https://www.instagram.com/p/DJnKYcno52w/\" rel=\"noopener noreferrer\" target=\"_blank\">@Stiervideo auf Instagram</a></li><li><a href=\"https://www.youtube.com/watch?v=nsmDyrOGuLg&amp;t=4s\" rel=\"noopener noreferrer\" target=\"_blank\">Willkommen im Mainstream | @ZDF Magazin Royale auf YouTube</a></li><li><a href=\"https://taz.de/!6084442/\" rel=\"noopener noreferrer\" target=\"_blank\">Hass hinter der Clownsmaske | taz</a></li><li><a href=\"https://www.merkur.de/boulevard/war-boehmermanns-clownswelt-aufdeckung-rechtmaessig-anwalt-analysiert-93729480.html\" rel=\"noopener noreferrer\" target=\"_blank\">Rechtsanwalt analysiert „Clownswelt“-Enthüllung – Ist Böhmermann zu weit gegangen? | Merkur</a></li><li><a href=\"https://www.instagram.com/p/DJmVBfMs742/?hl=de&amp;img_index=7\" rel=\"noopener noreferrer\" target=\"_blank\">@zapp.medienmagazin auf Instagram&nbsp;</a></li><li><a href=\"https://www.tiktok.com/@visit.yellowstone?_t=ZN-8wIUhRWVJ9q&amp;_r=1\" rel=\"noopener noreferrer\" target=\"_blank\">@visit.yellowstone auf TikTok</a></li></ul><p><br></p><p><strong>***Lästerschwestern ist eine Produktion der Richtig Cool GmbH.***</strong></p><hr><p style='color:grey; font-size:0.75em;'> Hosted on Acast. See <a style='color:grey;' target='_blank' rel='noopener noreferrer' href='https://acast.com/privacy'>acast.com/privacy</a> for more information.</p>"


var enjoyyourbike = """
    Das wir irgendwann keinen Zucker mehr sehen können, haben wir im Sport alle schon erlebt. Aber warum ist das so? Und wieso wissen viele viel zu wenig über den Wasser &amp; Salzhaushalt? Christian, Gründer von Rabbit Fuel gibt Euch viele eigene Erfahrungen und Tipps zum richtigen Essen während einer langen Aktivität.

    Mit Rabbit Fuel entstand aus dem Eigenbedarf ein Produkt, dass gerade bei langen Distanzen hilft etwas herzhaftes zu essen. Aber nicht nur das: es hilft am Ende auch, den Magen zu beruhigen, um wieder Gels &amp; Co. zu sich nehmen zu können. Christan gibt viele Insights und es sind sogar viele schöne Zitate entstanden, wie z.B. „Ich kann mir nichts dafür kaufen,  dass ich bei Strava gut aussehe.“. Hört rein, Ingo &amp; André haben viel gelernt und Ihr nehmt in jedem Fall auch sinnvolle Tipps mit.

    Link zu Rabbit Fuel bei uns im Shop:
    https://www.enjoyyourbike.com/rabbitfuel/ 
    Rabbit Fuel Website: https://www.rabbit-fuel.com/
    Rabbit-Fuel Instagram: https://www.instagram.com/rabbit_fuel/


    00:00:00 Intro: Ernährung im Sport
    00:03:32 Lockere A-B Fragen zum Thema Essen und mehr
    00:21:24 Christians sportlicher Hintergrund: Trailrunning, Bikepacking
    00:37:28 Ernährung: Ultracycling/Ultrarunning: Wie macht man das mit dem Essen?
    00:46:00 Zucker macht irgendwann nicht mehr satt: Die Entstehung von Rabbit Fuel
    01:33:04 Alltags-Ernährung: Vor dem Sport, nach dem Sport fuelen?
    01:53:22 Christians Ernährungsstrategie im Wettkampf
    02:00:37 Salzhaushalt! Ein unterschätztes Thema: wie &amp; wieviel Wasser &amp; Salz muss ich zuführen?
    02:19:52 Ernährungs-Unterschieden zwischen kurzen und langen Sport-Events
    02:21:35 Nach dem Sport: Protein-Hype ignorieren?
    02:37:05 Schlusswort: Wieder viel gelernt! Salz, Kohlenhydrate und Rabbit Fuel macht satt
    """

var serienjunkies = """
    <![CDATA[<p>In den USA läuft die wohl spannendste Woche des gesamten Serienjahres: die Upfronts. Im Podcast sprechen Adam und Bjarne über die wichtigsten Entscheidungen der großen Network-Sender. Welche Formate wurden verlängert oder abgesetzt? Außerdem geht es darum, wie die Upfronts im Lauf der Zeit an Bedeutung verloren haben. Zumal auch dieses Jahr wieder die Streamer rund um Netflix mit eigenen Nachrichten dazwischenfunken.</p><br><p>Wie beim SJ Weekly üblich, bleibt später noch Zeit, über aktuelle Serien und Staffeln zu quatschen. Vor allem die neue österreichische Comedy \"Drunter und Drüber\" bei Amazon Prime Video kommt gut dabei weg. Zum Finale von \"You\" ist auch noch einiges zu sagen. Obwohl die nächsten Neustarts der kommenden Woche schon in den Startlöchern stehen...</p><br><p><br></p><p>ANZEIGE:</p><p>Unlimited Datenvolumen bei der Telekom für euch und eure Liebsten – mit dem neuen MagentaMobil M Tarif im größten 5G-Netz. Mehr dazu auf: <a href=\"http://www.telekom.de/unlimited\" rel=\"noopener noreferrer\" target=\"_blank\">www.telekom.de/unlimited</a></p><br><p><br></p><p>Timestamps:</p><p>News:</p><p>0:00:00 UPFRONTS: Was passiert da eigentlich?</p><p>0:07:30 Welche Verlängerungen/Absetzungen haben uns besonders bewogen?</p><p>0:14:00 Streamer drängen sich immer mehr in die Upfronts-Woche rein</p><p>0:17:00 Nicolas Cage als Spider-Man, Neues “The Office” Spin-off</p><p>0:20:00 Netflix nimmt innovatives Serien-Feature offline</p><p>Reviews:</p><p>0:24:00 You Finale, Drunter &amp; Drüber</p><p>0:30:00 Bad Thoughts, The Four Seasons, Forever</p><p>Neustarts:</p><p>0:36:00 <a href=\"https://www.serienjunkies.de/docs/serienplaner.html\" rel=\"noopener noreferrer\" target=\"_blank\">https://www.serienjunkies.de/docs/serienplaner.html</a> </p><br><p><br></p><p>Bjarne</p><p>Bluesky:<a href=\"https://bsky.app/profile/bjarnebock.bsky.social\" rel=\"noopener noreferrer\" target=\"_blank\"> https://bsky.app/profile/bjarnebock.bsky.social</a></p><p>Sankt Podcast: <a href=\"https://open.spotify.com/show/0ztNeRqXyxw8Z5QpelTjnC\" rel=\"noopener noreferrer\" target=\"_blank\">https://open.spotify.com/show/0ztNeRqXyxw8Z5QpelTjnC</a>&nbsp;</p><br><p>Adam:&nbsp;</p><p>Twitter/ X:<a href=\"https://twitter.com/AwesomeArndt\" rel=\"noopener noreferrer\" target=\"_blank\"> https://twitter.com/AwesomeArndt</a>&nbsp;</p><p>Instagram:<a href=\"https://www.instagram.com/awesomearndt/\" rel=\"noopener noreferrer\" target=\"_blank\"> https://www.instagram.com/awesomearndt/</a>&nbsp;</p><p>Youtube:<a href=\"https://www.youtube.com/@AwesomeArndt\" rel=\"noopener noreferrer\" target=\"_blank\"> https://www.youtube.com/@AwesomeArndt</a></p><hr><p style='color:grey; font-size:0.75em;'> Hosted on Acast. See <a style='color:grey;' target='_blank' rel='noopener noreferrer' href='https://acast.com/privacy'>acast.com/privacy</a> for more information.</p>]]>
    """

var minkorrekt = """
    ...direkt von der Kanzlerwahl der Wissenschaft.
    <!-- wp:paragraph -->
    <p>+++ Minkorrekt Live: Wir sind mit \"Das M!perium schlägt zurück\" auf Tour! <a href=\"https://www.ticketmaster.de/artist/methodisch-inkorrekt-tickets/1005128\" data-type=\"link\" data-id=\"https://www.ticketmaster.de/artist/methodisch-inkorrekt-tickets/1005128\"><strong>Tickets bekommt ihr hier</strong></a> – möge die Wissenschaft mit euch sein! +++</p>
    <!-- /wp:paragraph -->
    <!-- wp:paragraph -->
    <p>+++<a href=\"https://linktr.ee/methodischinkorrekt\" target=\"_blank\" rel=\"noreferrer noopener\">Alle Werbepartner findet ihr in diesem Linktree</a>!+++</p>
    <!-- /wp:paragraph -->
    <!-- wp:paragraph -->
    <p>00:00:00 Intro<br>00:01:47 Kanzlerwahl<br>00:07:08 Klimaringvorlesung<br>00:23:38 Nicolas zu Gast bei: Was los, Wissenschaft?<br>00:26:18 Reini zu Gast bei: Auch interessant!<br>00:27:17 Isotopen-Experiment<br>00:39:19 Thema 1: “Die dunkle Seite der Erwartung”<br>01:08:41 Science Snack<br>01:22:44 Thema 2: \"Stabile Seitenlage\"<br>01:44:54 Schwurbel der Woche<br>01:55:32 Hausmeisterei<br>01:57:33 Outro Folge 74 \"Snickers\"</p>
    <!-- /wp:paragraph -->
    <!-- wp:paragraph -->
    <p>+++ Minkorrekt Live: Wir sind mit \"Das M!perium schlägt zurück\" auf Tour! <a href=\"https://www.ticketmaster.de/artist/methodisch-inkorrekt-tickets/1005128\" data-type=\"link\" data-id=\"https://www.ticketmaster.de/artist/methodisch-inkorrekt-tickets/1005128\"><strong>Tickets bekommt ihr hier</strong></a> – möge die Wissenschaft mit euch sein! +++</p>
    <!-- /wp:paragraph -->
    <!-- wp:paragraph -->
    <p>+++<a href=\"https://linktr.ee/methodischinkorrekt\" target=\"_blank\" rel=\"noreferrer noopener\">Alle Werbepartner findet ihr in diesem Linktree</a>!+++</p>
    <!-- /wp:paragraph -->
    <!-- wp:paragraph -->
    <p><strong>Die Klimaringvorlesung hatte ihre Auftaktveranstaltung</strong>. Wenn ihr Lust habt mehr zum Thema zu erfahren findet Ihr auf der Seite der UDE die <a href=\"https://www.uni-due.de/ude4future/ringvorlesung\"><strong>weiteren Termine</strong></a>.<br><br><strong>Wir waren zu Gast!</strong> Nicht zusammen sondern jeweils in einem anderen Podcast: Nicolas war zu Gast beim Podcast \"<a href=\"https://was-los-wissenschaft.letscast.fm/episode/22-der-diamant-casanova-mit-dr-nicolas-woehrl\"><strong>Was los Wissenschaft?!</strong></a>\" von Lisa Ringena und Jan Philipp Rudloff und Reini war bei \"<a href=\"https://auch-interessant.de/2025/05/07/wissenschaftskommunikation-mit-dr-reinhard-remfort/\"><strong>Auch interessant</strong></a>\" von Ali Hackalife.</p>
    <!-- /wp:paragraph -->
    <!-- wp:paragraph -->
    <p><strong>Thema 1 (Nicolas): </strong>\"<a href=\"https://elifesciences.org/reviewed-preprints/105753\"><strong>Die dunkle Seite der Erwartung</strong></a>\" – Der Placebo-Effekt hat einen dunklen Zwilling. Er ist leicht verführerisch und laut aktuellsten Untersuchungen sogar wirklich stärker. Die Rede ist vom Nocebo-Effekt, der genau wie sein guter Zwilling komplett ohne Wirkstoffe auskommt und uns bei falschen Erwartungshaltungen zusätzlich leiden lassen kann.</p>
    <!-- /wp:paragraph -->
    <!-- wp:paragraph -->
    <p><strong>Science Snack</strong>: \"Espresso-Energie\" – Wie viel Energie braucht man eigentlich um einen Espresso zuzubereiten. Man könnte jetzt irgendeine Joule Zahl nennen, aber wir versuchen es hier mal etwas anschaulicher. </p>
    <!-- /wp:paragraph -->
    <!-- wp:paragraph -->
    <p><strong>Thema 2 (Reini):</strong> \"<a href=\"https://www.nature.com/articles/s42005-025-02087-0\"><strong>Stabile Seitenlage</strong></a>\" – Häufig glauben wir etwas zu wissen ohne genau sagen zu können warum. Manchmal ist es einfach \"gesunder Menschenverstand\" oder die plausible Herleitung einer Eigenschaft. Dabei kann man aber auch richtig daneben liegen wie die Untersuchungen an etwa 200 Eiern in den USA gezeigt haben.</p>
    <!-- /wp:paragraph -->
    <!-- wp:paragraph -->
    <p><strong>Schwurbel der Woche</strong>: \"<strong><a href=\"https://www.aurachirurgieonline.com\">Aurachirurgie</a></strong>\" – Es gibt nichts was es nicht gibt! Wenn wir schon keine genaue Definition haben was eine Aura sein soll, warum sollten wir daran nicht trotzdem herumdoktern können. Schnippelt an eurer Aura für geschmeidige 15.000€.</p>
    <!-- /wp:paragraph -->
    <!-- wp:paragraph -->
    <p><strong>Hausmeisterei</strong>: <strong><a href=\"https://minkorrekt.de/minkorrekt-live/\" data-type=\"link\" data-id=\"https://minkorrekt.de/minkorrekt-live/\">Wir sind auf Tour und einige Termine sind ausverkauft</a></strong>. Trotzdem lohnt es sich, da hin und wieder mal zu schauen, ob es nicht doch noch Tickets gibt. Manchmal werden einzelne Tickets doch noch kurzfristig frei.</p>
    <!-- /wp:paragraph -->
    <!-- wp:paragraph -->
    <p><strong>Outro: Intro <a href=\"https://minkorrekt.de/minkorrekt-folge-74-marslos/\">Folge 74</a> \"Snickers\"</strong></p>
    <!-- /wp:paragraph -->
    <!-- wp:paragraph -->
    <p><strong>Minkorrekt live: Das sind die nächsten Termine</strong>:</p>
    <!-- /wp:paragraph -->
    <!-- wp:paragraph -->
    <p><strong><a href=\"https://www.ticketmaster.de/event/546969?camefrom=GLSmethodisch_inkorrekt&amp;language=de-de&amp;subchannel_id=1&amp;track=DiscoveryAPI\" data-type=\"link\" data-id=\"https://www.ticketmaster.de/event/546969?camefrom=GLSmethodisch_inkorrekt&amp;language=de-de&amp;subchannel_id=1&amp;track=DiscoveryAPI\">17.05.2025 Trier</a></strong><br><strong><a href=\"https://www.ticketmaster.de/event/546939?camefrom=GLSmethodisch_inkorrekt&amp;language=de-de&amp;subchannel_id=1&amp;track=DiscoveryAPI\" data-type=\"link\" data-id=\"https://www.ticketmaster.de/event/546939?camefrom=GLSmethodisch_inkorrekt&amp;language=de-de&amp;subchannel_id=1&amp;track=DiscoveryAPI\">25.05.2025 Bonn</a></strong> <strong>(RESTKARTEN!)</strong><br><strong><a href=\"https://www.ticketmaster.de/event/541787?camefrom=GLSmethodisch_inkorrekt&amp;language=de-de&amp;subchannel_id=1&amp;track=DiscoveryAPI\" data-type=\"link\" data-id=\"https://www.ticketmaster.de/event/541787?camefrom=GLSmethodisch_inkorrekt&amp;language=de-de&amp;subchannel_id=1&amp;track=DiscoveryAPI\">14.06.2025 Heilbronn</a></strong><br><strong><a href=\"https://www.ticketmaster.de/event/541793?camefrom=GLSmethodisch_inkorrekt&amp;language=de-de&amp;subchannel_id=1&amp;track=DiscoveryAPI\" data-type=\"link\" data-id=\"https://www.ticketmaster.de/event/541793?camefrom=GLSmethodisch_inkorrekt&amp;language=de-de&amp;subchannel_id=1&amp;track=DiscoveryAPI\">15.06.2025 Neu Isenburg</a></strong><br><strong><a href=\"https://www.ticketmaster.de/event/545765?camefrom=GLSmethodisch_inkorrekt&amp;language=de-de&amp;subchannel_id=1&amp;track=DiscoveryAPI\" data-type=\"link\" data-id=\"https://www.ticketmaster.de/event/545765?camefrom=GLSmethodisch_inkorrekt&amp;language=de-de&amp;subchannel_id=1&amp;track=DiscoveryAPI\">12.07.2025 Berlin</a></strong> <strong>(RESTKARTEN)</strong><br><strong><a href=\"https://www.ticketmaster.de/event/545767?camefrom=GLSmethodisch_inkorrekt&amp;language=de-de&amp;subchannel_id=1&amp;track=DiscoveryAPI\" data-type=\"link\" data-id=\"https://www.ticketmaster.de/event/545767?camefrom=GLSmethodisch_inkorrekt&amp;language=de-de&amp;subchannel_id=1&amp;track=DiscoveryAPI\">13.07.2025 Berlin</a></strong><br><strong><a href=\"https://www.ticketmaster.de/event/546421?camefrom=GLSmethodisch_inkorrekt&amp;language=de-de&amp;subchannel_id=1&amp;track=DiscoveryAPI\" data-type=\"link\" data-id=\"https://www.ticketmaster.de/event/546421?camefrom=GLSmethodisch_inkorrekt&amp;language=de-de&amp;subchannel_id=1&amp;track=DiscoveryAPI\">14.09.2025 Bielefeld</a></strong><br><br><strong>uvm! <a href=\"https://minkorrekt.de/minkorrekt-live/\" data-type=\"link\" data-id=\"https://minkorrekt.de/minkorrekt-live/\">Alle weiteren Termine gibt es hier!</a></strong></p>
    <!-- /wp:paragraph -->
    <!-- wp:paragraph -->
    <p><strong>Wichtige Adressen:</strong></p>
    <!-- /wp:paragraph -->
    <!-- wp:paragraph -->
    <p><strong><a href=\"https://minkorrekt.de/minkorrekt-live/\" data-type=\"link\" data-id=\"https://minkorrekt.de/minkorrekt-live/\">Unsere Live-Termine und Tickets für unsere neue Show findet ihr hier!</a></strong></p>
    <!-- /wp:paragraph -->
    <!-- wp:paragraph -->
    <p>Zu unserem <strong><a href=\"https://minkorrekt.de/minkorrekt-newsletter/\" data-type=\"link\" data-id=\"https://minkorrekt.de/minkorrekt-newsletter/\">Newsletter könnt ihr euch hier anmelden</a></strong>!</p>
    <!-- /wp:paragraph -->
    <!-- wp:paragraph -->
    <p><strong><a href=\"https://chaos.social/deck/@minkorrekt\" data-type=\"link\" data-id=\"https://chaos.social/deck/@minkorrekt\">Folge uns gerne auf Mastodon</a></strong>, <strong><a href=\"https://www.instagram.com/methodisch_inkorrekt/\" data-type=\"link\" data-id=\"https://www.instagram.com/methodisch_inkorrekt/\">Instagram</a></strong> oder<strong><a href=\"https://www.youtube.com/@methodischinkorrekt2348\"> YouTube</a></strong>!</p>
    <!-- /wp:paragraph -->
    <!-- wp:paragraph -->
    <p>Hier findet ihr <a href=\"https://discord.gg/PZ3cTUdMNx\"><strong>unseren Discord</strong></a></p>
    <!-- /wp:paragraph -->
    <!-- wp:paragraph -->
    <p><a href=\"http://www.modisch-inkorrekt.de/\"><strong>Modisch inkorrektes Merch</strong></a> gibt es hier!</p>
    <!-- /wp:paragraph -->
    <!-- wp:paragraph -->
    <p>Minkorrekt! ohne Werbung bekommt ihr bei&nbsp;<strong><a href=\"https://steadyhq.com/de/minkorrekt/about\" target=\"_blank\" rel=\"noreferrer noopener\">Steady</a></strong></p>
    <!-- /wp:paragraph -->
    <!-- wp:paragraph -->
    <p>Hier findet ihr alle <a href=\"https://minkorrekt.de/support/\"><strong>Möglichkeiten, uns zu unterstützen</strong></a>!</p>
    <!-- /wp:paragraph -->
    """

var leadDevPriorityZero = """
    <![CDATA[<p>Allison Malloy, Director of Engineering at Shopify, joins the show to chat about her journey from aspiring astronaut to a successful career in software engineering. We talked about her unintentional path to management, the challenges of running a remote team, and her Priority Zero of unifying services across Shopify.</p>
    <p>08:40 Transitioning to management: The unintentional leader</p>
    <p>14:00 Managing managers and the importance of letting go</p>
    <p>17:30 What makes a great technical manager</p>
    <p>19:50 Working fully remote from Canada</p>
    <p>24:00 Unification of teams and features at Shopify and expanding future capabilities</p>
    <p>33:00 Setting the right goals for major projects and launches</p>
    <p>Allison's recommendation: The Acquired podcast and The Art of Storytelling by John D. Walsh.</p>
    ]]>
    """

dump(extractTimeCodesAndTitles(from: laesterSchwester))
dump(extractTimeCodesAndTitles(from: rasenfunk))
dump(extractTimeCodesAndTitles(from: enjoyyourbike))
dump(extractTimeCodesAndTitles(from: serienjunkies))
dump(extractTimeCodesAndTitles(from: minkorrekt))
dump(extractTimeCodesAndTitles(from: leadDevPriorityZero))


func extractTimeCodesAndTitles(from htmlEncodedText: String) -> [String: String] {
    var result = [String: String]()
    
    let pattern = #"<li>(\d{2}:\d{2}:\d{2}) (.*?)</li>"#
    let regex = try! NSRegularExpression(pattern: pattern, options: [])
    
    let matches = regex.matches(in: htmlEncodedText, options: [], range: NSRange(location: 0, length: htmlEncodedText.utf16.count))
    
    for match in matches {
        if let timeRange = Range(match.range(at: 1), in: htmlEncodedText),
           let titleRange = Range(match.range(at: 2), in: htmlEncodedText) {
            let timeCode = String(htmlEncodedText[timeRange])
            let title = String(htmlEncodedText[titleRange])
            result[timeCode] = title
        }
    }
    
    return result
}
