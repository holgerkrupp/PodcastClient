import SwiftUI

extension Set where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var addedDict = [Element: Bool]()

        return filter {
            addedDict.updateValue(true, forKey: $0) == nil
        }
    }

    mutating func removeDuplicates() {
        self = Set(self.removingDuplicates())
    }
}


struct TranscriptListView: View {
    let vttContent: String
    @State private var searchText: String = ""
    
    // Predefined colors for speakers
    private let speakerColors: [Color] = [
        .blue,
        .green,
        .orange,
        .purple,
        .red,
        .teal
    ]
    
    private var speakerColorMap: [String: Color] {
       
        var colorMap: [String: Color] = [:]
        let speakers = Set(filteredLines.compactMap { $0.speaker }).removingDuplicates().sorted(by: <)
    
        
        for (index, speaker) in speakers.enumerated() {
            colorMap[speaker] = speakerColors[index % speakerColors.count]
        }
       
        return colorMap
    }
    
    
    
    private var filteredLines: [TranscriptDecoder.TranscriptLineWithTime] {
        let allLines = TranscriptDecoder(vttContent).transcriptLines
        if searchText.isEmpty {
            return allLines
        }
        return allLines.filter { line in
            line.text.localizedCaseInsensitiveContains(searchText) ||
            (line.speaker?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
    
    var body: some View {
        VStack {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                TextField("Search transcript...", text: $searchText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .padding()
            
            // Transcript list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(groupedLines(), id: \.id) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(formatTime(group.startTime))
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                
                                if let speaker = group.speaker {
                                    Text("\(speaker):")
                                        .font(.headline)
                                        .foregroundColor(speakerColorMap[speaker] ?? .accent)
                                }
                            }
                            Text(group.text)
                                .font(.body)
                                .foregroundColor(.primary)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    Player.shared.jumpTo(time: group.startTime)
                                }
                        }
                        .padding(.horizontal)
                        Divider()
                    }
                }
            }
        }
    }
    
    private func groupedLines() -> [TranscriptDecoder.TranscriptLineWithTime] {
        var grouped: [TranscriptDecoder.TranscriptLineWithTime] = []
        var currentSpeaker: String?
        
        for line in filteredLines {
            if let speaker = line.speaker {
                // New speaker or first line
                if speaker != currentSpeaker {
                    currentSpeaker = speaker
                    grouped.append(line)
                } else {
                    // Same speaker, append text to the last entry
                    if var lastLine = grouped.last {
                        lastLine.text += " " + line.text
                        grouped[grouped.count - 1] = lastLine
                    }
                }
            } else {
                // No speaker, always add as new line
                grouped.append(line)
                currentSpeaker = nil
            }
        }
        
        return grouped
    }
    
    
    
    private func formatTime(_ timeInterval: TimeInterval) -> String {
        let minutes = Int(timeInterval) / 60
        let seconds = Int(timeInterval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}




#Preview {
    let WaitingForReviewText = """
        Daniel (00:09)
        Dave, how do you feel about cold opens? I don't care. I'm going to open coldly. So I have a thing. have a thing where I personally with my private money, I'm sponsoring a tiny podcast. I don't know if it's so tiny, but like I'm sponsoring a smallish podcast via Patreon because they will read the list of their gold sponsors at the top of every episode. So most of them, I will just...

        David Gary Wood (00:14)
        cold opens.

        Ooh, feeling that.

        Daniel (00:37)
        So they will just like read out this and this and this and also telemetrydeck.com. So I think it's kind of cool. The podcast is the Shift F1 podcast, if anyone is interested. I love that podcast. It's like such a fun, fun take on Formula One. And recently people have started changing their Patreon names every now and then in reaction to events in the Formula One world.

        David Gary Wood (00:47)
        Meow.

        Awesome.

        Daniel (01:00)
        Basically, they will have to make them read the new names, right? And that was kind of like a fun game. Every now and then, every episode, you're like, okay, what have people changed their names to? Now, the person that is just like two entries behind me, think, has changed their name to Cigarettes. So it's like, the Shift Everyone Podcast is now sponsored by Cigarettes.

        David Gary Wood (01:20)
        Cigarettes.

        Daniel (01:22)
        And telemetrydeck.com. ⁓

        David Gary Wood (01:23)
        Oh my word. Oh

        Daniel (01:27)
        So yeah, I'm thinking I have to change my name to something, but I don't know what.

        David Gary Wood (01:32)
        You need to have like a sort of Boaty McBoatface kind of name. Like, I don't know enough about F1 to create one, but yeah, something like that. Maybe just for the lols.

        Daniel (01:44)
        Hans Hermann.

        But anyway, enough of Formula One or other podcasts, this is Waiting for Review, a show about a tiny, now about the majestic indie developer lifestyle. Join your scintillating hosts to hear about a tiny slice of their thrilling lives. I'm Daniel, the technical founder of telemetrydeck.com, and I'm here with Daddy of the Week, Dave. Join us while Waiting for Review.

        David Gary Wood (02:05)
        ⁓

        Daddy of the week. Thank you. It's not even Father's Day.

        Daniel (02:10)
        Everyday is Father's Day somewhere.

        David Gary Wood (02:12)
        True, true. I think I'm turning into like the cat daddy these days. We've got two cats again now in our house and yeah, that's very nice. Our kitten is growing up well. But yes, she's not around. So I feel like I can't add her as a guest on the show, but maybe I'll do that so people can just see her picture.

        Daniel (02:18)
        Aww, well that's nice.

        David Gary Wood (02:35)
        If you go to the Waiting for Review website and you look at our show guests, you'll notice that all of our cats are in there because of the various times that they've crashed calls. So yeah, I think maybe I'll put our new cat Sylvie there just because.

        Daniel (02:46)
        Mm-hmm.

        yes, please, what's her name?

        David Gary Wood (02:53)
        Sylvie. Yeah, although she gets called all sorts as most cats do. she's Sylvie, Velcro kitten, because she attaches herself to a human and just sits there. Yeah. But yeah, she's really sweet. Another tabby cat. And her name is Sylvie and our other cat is called Stevie. So it kind of gets a bit confusing at times. And then they both

        Daniel (02:55)
        Sylvie.

        Of course, of course.

        That's adorable.

        David Gary Wood (03:20)
        look the same because they're tabbies. So yeah, we've set ourselves up for confusion, but they know who they are and they know where the food is. And yes, they're very sweet. Yes.

        Daniel (03:33)
        That's the most important thing. Speaking

        of pet nicknames, Mimi and Momo are sometimes called Dumpling and Sausage because one of them is like small and round and the other one is more longish.

        David Gary Wood (03:44)
        You

        or.

        Well, where are we with the show?

        Daniel (03:45)
        We

        actually got selfies. So last episode or over the last few episodes, think, we told people, if you are at this point in the show, send us a selfie. And we actually did get selfies. That was so cool. I loved it because it was like, yeah, people are actually listening to us while they were out and about. They were at home or on their desks.

        David Gary Wood (03:51)
        Yes!

        Mm-hmm.

        Yes.

        Daniel (04:10)
        And that was really cool. So shout out to, like, do we read the names of the people who send us that? All right. Cool. Cool. So one person, Joe Heck, with an exclamation mark, ⁓ sent us a selfie from a walk. As did Holger. He was also wearing a t-shirt with a podcast, Bits und So, which is German for bits and stuff. Also kind of fun podcast.

        David Gary Wood (04:14)
        Yeah, go for it.

        Yep. Yep.

        Mm-hmm.

        Mm-hmm.

        Daniel (04:34)
        Also Lisa, who you might know as the CEO of telemetrydeck.co.

        David Gary Wood (04:41)
        Mm-hmm. So yeah, some good selfies there. We should. Well.

        Daniel (04:43)
        So yeah, I like that. I like that. We should continue doing that, asking people to do stuff. But

        I wanna one up it, which is if you have a chore that needs to be doing, like right now, you can start doing that. You can just listen to us ramble about bullshit basically, and do the thing that you did. And then you can tell us or selfie us that you are proud of having like progressed your chore by

        David Gary Wood (05:01)
        He

        Daniel (05:09)
        30 minutes or whatever. Like if you're not done, it's fine. But just like start, start. You can do it. We believe in you.

        David Gary Wood (05:14)
        Absolutely. I

        want to see the vacuuming or whatever it is you're doing right now. Like take a selfie in that moment or take a selfie of the job well done and tag us, email us, whatever way you feel most comfortable. Although I will say if you post on social media, we can link you in the show notes as well. So there's a motivator. Tag us on the mastodons and we'll do that.

        Daniel (05:40)
        Do not

        send homing pigeons though, they kinda mess up the balcony.

        David Gary Wood (05:41)
        It's fun to see.

        Yeah, yeah, they do. had to stop that. That just didn't work.

        Daniel (05:48)
        That's another chore for me even.

        David Gary Wood (05:51)
        Yes. And yeah, awesome. I definitely look forward to seeing people's selfies. It's always fun to see and you get a tiny slice of our scintillating lives. We would like a tiny slice of yours.

        Daniel (06:05)
        scintillating slice of your tiny life. That sounds wrong. the cats are very scintillating too. Did you hear that? They're just kind of like zooming, zooming through, like just there right next to me. I need to add like behind me.

        David Gary Wood (06:07)
        There we go. Yeah, that sounds wrong.

        I did not.

        Right, I'm gonna do it when I post.

        Yeah, you need a cat cat's shelf behind you. I'm gonna do a thing where on this show, if you go to the show notes, I will add all of the cats to the guests. And then you can see their little profile.

        Daniel (06:21)
        Catch y'all.

        Hahaha

        That's very important. Yeah, you're writing it down even. Cool. Do you want to hear about the thing that we didn't talk about last time because we were kind of time-constrained? Where I was like deep in the server minds and came back with lots of performance goals.

        David Gary Wood (06:37)
        I am, I am.

        ⁓ Sorry, no, absolutely, absolutely I do. Let's get into it.

        Daniel (06:52)
        You don't want to hear it? Okay, fine. So next up.

        Okay, so as you may know, I am by now probably one of the most prolific users of Apache Druid, at least on the European continent, which is kind of a strange thing to say. I even have open pull requests that are probably about to be accepted, hopefully, in the project. I ⁓ kind of could count myself as a...

        David Gary Wood (07:19)
        Ooh, you're a contributor.

        Daniel (07:22)
        contributor, but one of the tests is still failing. I've got to look at that. The reason behind this is because I want to have a good performance for our customers who want to see all their data. For a long time, everything was slowish and breaky. No one else in the druid world was talking about it. Everyone was like, oh yeah, we loaded like

        David Gary Wood (07:23)
        Yeah.

        Daniel (07:46)
        gigs of data, terabytes of data into this and just worked and was very fast. And, yeah, we use this feature and it just worked and like nothing ever worked for us. so I did lots of experiments, which take ages of time, found a few things, like a few like special characters that are kind of not allowed. I think I told you about this year, months ago. Other things that I like.

        I just had a few, had lots of experiments, experiments running. And basically the results are in the result is the width of our data source is the problem, which means that every line in our quote unquote database has just like infinitely many fields because it basically takes all the fields of all the customers. if like someone, if you send a telemetry deck signal or event that has a property that says like, I don't know, is Daniel recording a podcast and

        You set that to true. Then now we have a field that is called is Daniel recording a podcast. This is just how this data, this type of database works. And they say in the documentation, this is totally fine. Like we can, we can do as many fields as you want. the, don't care at all about it. It turns out they do care. Like at least the code cares or at least memory cares. Like I've been like upgrading servers with higher and higher RAM to just stay on top of that. And like you just reach a breaking point.

        David Gary Wood (08:35)
        Mm-hmm.

        Daniel (09:02)
        And so the solution finally was the following, splitting up the data sources. Like this might seem obvious, but it's actually not that easy, both from a standpoint where you want to like convert people from the old to the new, but also like if I have too many data sources, this will, this would be another performance problem. But I have like the main thing that I kind of found out is if I have two data sources, one is the big one where all the data lives in.

        And then the second one is exactly the same, but it only contains the fields that the telemetry SDK sends or can send. So that's about like 50 to 80, I think. ⁓ And that's it. Like all the data, but only the fields that we know about. And that thing is so much nicer to deal with. It fits into the RAM. It can be compacted, which is like...

        David Gary Wood (09:38)
        Mm-hmm. Yep.

        right.

        Daniel (09:54)
        Like we can be defragmented. can be distributed. The optimization techniques all work. A query on the big database, according to, I haven't looked today, but I have this dashboard basically that tells me how long queries do run. And a normal priority query on the big data source waits about five seconds for other queries to finish and then takes about two seconds to calculate.

        A query on the small data source waits about half a second and takes about 0.02 seconds to calculate.

        David Gary Wood (10:24)
        That's what you want. Yeah.

        Daniel (10:26)
        And so with that, I have now switched over all the default charts, all of them to the tiny data source and so much faster. And then I had a long conversation with my good friend, Konstantin, about caching. And he was like, yeah, yeah, but like most of the results are these like individual results per day, right? Like users per day or whatever. So.

        Why don't you, like, instead of caching the whole result, why don't you cache the individual days and kind of like, take, combine this stuff. And so I kind of dive deep into like, how do I, like take the results that the database gives me and then kind of like, pull them apart and have like cache and validation logic and stuff like that. How do I fit it, fit that in into my caching layer? And then while I was researching that I found out that there's, caching functionality built in.

        It is just A, very hidden and B, in a separate community package and C, I needed to add a pull request to make that work. But then the server just does it for me. that gave me another twofold increase in performance, even with the big data source.

        David Gary Wood (11:29)
        What?

        Yeah, yeah, that's awesome.

        Daniel (11:33)
        for the

        cost of just one single little tiny memcached server. So yeah, that's the second thing. Oh yeah, and the third thing is I moved servers again. That's just a thing I do every year. Now I kind of pick and choose a new host and just move all the servers there. No joke, I'm joking, but a lot of our...

        David Gary Wood (11:45)
        Right, as you do. Yep, yep.

        is the annual migration of the servers.

        Daniel (11:57)
        Like in the spring we bring them up the mountain and then in the fall we just like purred them down the mountain again to get their milk and stuff. Most of the calculation servers now live at Hetzner in Germany. And that is cool because they have bare metal servers and those have even better disk performance, especially if it's as these NVMe SSDs. Like of course,

        David Gary Wood (12:12)
        Mm-hmm.

        Yes. Yes.

        Daniel (12:24)
        On AWS we have designated SSD machines, still the performance is even more immediate. And you can also see that in the data. That's also just better for the performance. So yeah, that was eight weeks of my life, if even that. ⁓

        David Gary Wood (12:30)
        Yes.

        That's a lot of work.

        Yeah. Yeah.

        So for listeners

        Daniel (12:45)
        finally some wins, you know?

        David Gary Wood (12:45)
        of the show that use telemetry deck, for listeners of the show that listen to telemetry deck, all of your charts, all of your queries are now very optimized from the sounds of that.

        Daniel (12:57)
        such optimization. Hang on, let me give you the dashboard.telemj.com. And I have like, where is this? Cray service dashboard calculation duration. ⁓ Hang on. ⁓ can show this, not this. Let me scroll in a way. Okay, I can tell you some numbers first that you can't see because there's like customer names in there.

        David Gary Wood (12:59)
        Nice.

        Is this something you can show Daniel? Is it okay to screen share?

        for the YouTubes.

        Mm-hmm.

        Daniel (13:25)
        because I kind of split it up by customers. So, but like the big data source currently takes around two-ish seconds to calculate and the small one 0.21 seconds. But I can show you this. Hang on. I will describe that any charts that I'm sharing as well for the audio listeners. So this is one of the more important dashboards that I've been looking at for a long time, which is...

        David Gary Wood (13:41)
        Yes.

        Daniel (13:50)
        ⁓ Just like how long do people wait until the calculation is already actually finished? Or like how long does the actual calculation, we have a queuing system. I've improved that as well. It has now round drop-in by ⁓ owner, which is your organization basically, which is better than first in first out, because if someone just clicks around randomly, they don't clog up the whole queue for everyone. ⁓ And basically what you see is like, if I just take the...

        the median calculation duration, then we have a chart that goes kinda between, let's say, ⁓ two seconds at max, and then, I don't know, maybe one second-ish at min, like before I kinda, like, that was kinda also when I was still already testing stuff out. But like, and then we have, like a few days ago, when I was finally like putting all these things together, we have a sharp drop off.

        And it goes down to 0.2.

        David Gary Wood (14:53)
        amazing. Yeah, seeing the visual there, you can you can literally see where you turn it on. That's great.

        Daniel (14:54)
        And that's course multiplied by the fact.

        Right. And that's also multiplied by the fact, of course, that now more calculations are using the quick data source. So if I just go way down past the stuff that I don't want to show because it has customer names in it, I have another chart. Calculation runs by data source. so there's a pink line that is the new small data source and a blue line that is the big data source. And it also shows that beginning of May, the two lines are crossing.

        David Gary Wood (15:11)
        Mm-hmm.

        Daniel (15:28)
        And the pink line is now on top, which is awesome because it means that now more calculations run through the small data source because most calculations are just the default charts, like the little widgets you have on top of your dashboard, the number of users charts, stuff like that. ⁓ So yeah, that is kind of cool. ⁓

        David Gary Wood (15:31)
        Yeah.

        This is fantastic.

        And you've got Q duration there with the drop off again. yeah, count duration as a histogram. This is awesome. Yeah.

        Daniel (15:57)
        Mm-hmm.

        Oh yeah, I love histograms these days. We now have

        the ability to have histograms. And this is a logarithmic histogram of the calculation duration. And it shows you that, especially in the last few days, it skews heavily towards below 0.25 seconds for all calculations. And then there's a long tail that goes up to, I don't know, 128 seconds or so, with a few that take 2,048 seconds to calculate.

        David Gary Wood (16:12)
        Mm-hmm.

        Yeah.

        Daniel (16:32)
        which is mostly a bug. ⁓ But yeah, so this is what I've been working on. ⁓ having proper analytics on it has really helped me find out. Because I can change something and it feels faster for me. But if it doesn't move the needle for most people, then it's kind of useless. What else do we have? ⁓ we almost know calculation errors. And yeah, it is.

        David Gary Wood (16:53)
        I love it and I love the fact you're dog fooding.

        You know, this is dog fooding, Daniel. You're using your own product to

        analyze your products and making it better. That's wicked.

        Daniel (17:01)
        It is. Yes.

        This is, I had like, I made this chart. This is a chart that says like how many, well, what type of calculations are people actually using? Like we have like time series queries and like scan queries and whatever. And I wanted to know like how many people are using time series versus other types of queries because I like with, I wanted to like, I wanted to try the caching thing myself.

        David Gary Wood (17:17)
        Mm-hmm.

        Daniel (17:34)
        And that would have only worked on time series queries. And time series queries are actually the most popular query on TNMTD. But with like 20,000 per day, calculations per day-ish. But then top end is like 11,000 per day-ish. And I wouldn't have been able to cache those with the methods that I wanted to do. So I'm happy that I found a built-in ⁓ method.

        David Gary Wood (17:37)
        Right.

        Yes.

        Mm-hmm.

        Right, but you are now with...

        Yeah, that's awesome. Again, guiding your approach through taking a look at this data. Which of course you do, right? I wouldn't have expected anything less from you, but like, it's really cool to see it, Daniel. Yeah.

        Daniel (18:04)
        Yeah.

        Yeah

        things. But the thing

        is, I'm like, this is something I've spoken of spoken about a few times already. The more and more I'm kind of going into this mindset of like, I really want to have things that are that are tiny and modular in a way that I can reuse them. And it's hard to describe that because everyone always says that they always want things to be modular and decoupled and whatever.

        David Gary Wood (18:40)
        yeah. Yeah.

        Daniel (18:41)
        And what I mean is not individual classes or whatever. What I mean is like actual, like whole features that they should be reusable. for example, and like if I have a feature that like I plan, I'm trying to think, okay, how can I make this as small as possible, but also like not block any development in the future. And for example, like I've started like

        David Gary Wood (18:49)
        Mm-hmm.

        Daniel (19:09)
        months ago to work on a concept called namespaces where individual customers could have their own database like that's completely, completely separated. And that is now powering so much because it's powering the fact that we now have two data sources that are, those are just namespaces that you kind of like, that are kind of the default namespaces. And also we were, we were able to like extract individual, very large customers into their own data databases, into their own namespaces, which has also helped their performance.

        even with custom queries that go deep into their data because they can just do it. The other thing is also that I can allow individual customers to go as far back into the past as they want to because if it's just one customer, can load way more data of theirs into the server. Yeah, these are all features that are just available in the backend right now, but I also want to have them as things you can pay for basically at some point.

        David Gary Wood (19:58)
        makes sense.

        Yeah. And then, you know, it's the sort of thing that you access when you need it and kind of helps pay its way in terms of the support, maintenance and everything else that goes into making it happen. I love that. That's a good way of doing it. Damn, you've been busy. Yeah. I had...

        Daniel (20:21)
        Darn, I have been busy. ⁓ yeah. Like so much server

        stuff, like all the modular stuff was really helpful. Also the moving servers was way easier than I thought it would be because Ansible, because we tried from the start to have the, when we did like when we like lots of, when we did lots of server work last year, we very consciously chose a technology that would be very platform agnostic and not just work on AWS or Azure or whatever.

        And so with Ansible, I can just buy a new server from Hetzner, which is an actual physical machine somewhere, and Nuremberg spins up. And then just point the Ansible at this and be like, you are historical four.

        David Gary Wood (21:02)
        and it just

        provisions and does what it needs to do. And I love that as well because that's payback for that investment, right? That overhead of going that way. Yeah, love it when a plan comes together.

        Daniel (21:06)
        Yes.

        David Gary Wood (21:17)
        Oh, so you've been busier than I, Daniel. Yeah, I'm trying to think back to the last show. I talked about my exploration of Qt, looking at cross-platform tooling. Yes, I'm Qt. Yeah, and I've done a little bit of that, but honestly, not as deeply.

        Daniel (21:19)
        ⁓ Yeah.

        We were talking about some cutie.

        David Gary Wood (21:42)
        as I might've liked, time just hasn't really worked out that way this week. I definitely have a bit of time blocked out this weekend to go deeper again. Still in the exploration phase, I mean, I'm excited about it and about the potential of what it can give me, but I don't know if it's gonna work out. So I do have to have a level of pragmatism here is that I give it some time. If it looks promising, keep going.

        if I hit big dead ends, then I need to reroute as it were and have another think. But I'm actually looking forward to just spending some proper time with it because it's fun. I'm learning something new and I like learning new things. So yeah, definitely want to have more to talk about to that on future shows. But what I did do,

        across this last week, well mainly last weekend, I actually managed to release some updates. Well, an update to Govj. So I looked at the store and I hadn't released an update since January. What? Sure, I must have had more than that. And of course, what happened is that I had an update that was ready to go just before I took my break.

        across April and took all the time I needed at that point for health. And the update had got ground down in App Store review. They rejected it for a reason that I couldn't duplicate. And in that moment, I was just like, yes, screw this. I need to not be doing this because actually it's too frustrating. So I picked everything back up.

        Daniel (23:06)
        Yeah. ⁓

        Did you add

        payments that was also the App Store Dave? Again.

        David Gary Wood (23:14)
        Uh,

        no, no, not again. Um, but so that, that might be an epic fail if I did. no, mean, I'm tempted just given Apple's behavior. Um, but, uh, no, um, it was payment related. They couldn't close the paywall and I could not reproduce it. I tried, I spent a bit of time, different devices and things and you know, loading the app from cold.

        Daniel (23:20)
        No.

        David Gary Wood (23:44)
        as it were, absolutely brand new and just testing it through and couldn't repeat it. So I started preparing the update and there's a couple of minor things that it needed. I fixed landscape mode on the iPad because that's been broken for some time now. It came down to a one line piece of code, right, to just

        sort the UI out because it was scaling badly. was creating the preview I've got for the video was turning into a really small little rectangle at the top. And then the previews for either channel of video were expanding too big. That's all it was. They just needed a constraint putting in as it were.

        Daniel (24:24)
        You gotta show some constraint Dave.

        David Gary Wood (24:26)
        Exactly, exactly. So I did that, pulled that together, put the build through, it was approved. Didn't do anything to the paywall. ⁓ I don't know what they were experiencing there. But yeah, it's a little frustrating because I have two apps, right, for Govj. I have Govj and then I have Govjedu edition.

        Daniel (24:36)
        You

        David Gary Wood (24:51)
        And the EDU edition is exactly the same app, but without any of the subscriptions or in-app purchase options, it is a paid only app. And it costs exactly the same as my lifetime upgrade in-app purchase in the main app. But it's the EDU edition for education, and it enables people who are using the Apple School Manager or something like that.

        So when they're using MDM and they're managing a fleet of devices, they can buy the app from the app store and load it onto the devices. What they can't do in that scenario is use in-app purchases or subscriptions. So hence a separate app. A school contacted me about a year ago and yeah, yeah. And I've sold to other places since.

        Daniel (25:36)
        Yeah, I do remember that was a whole thing, right?

        David Gary Wood (25:41)
        Right, periodically I get a flurry of purchases because I have to buy one per device. And I offer the educational discount there as well, I think. So that's turned on. They can get a discount.

        Daniel (25:54)
        Dave Wood,

        school millionaire, like making his billions on the backs of school children.

        David Gary Wood (25:57)
        Yeah.

        Exactly. Selling apps to the kids. No. So yeah, I have two apps and the issue was that Apple rejected one of them and approved the other. So at the moment the landscape update isn't on the EDU version. I've just shipped the update on main.

        Daniel (26:14)
        Ha

        David Gary Wood (26:23)
        And then the EDU's got the previous build from before. And then I'm going to have to release another version and bring them both in line again. But it was better to just move on for me at that time. And then like I say, on the very next update, everybody will be together again. But if it happens again, I know I should think, you reject the build after it's been approved and start again?

        I don't think I've been through that before. So anyway, this is a thing and it's something I'm going to have to be more mindful of. think, just, just running the two cause they should be kept in lockstep. but it is frustrating and I kind of wish I could just tick a box to, you know, say that this is a edu version or something and have a toggle somewhere where the paywall doesn't show and everything's

        open and it's just the same app but it's another edge case of Apple's payment system and the way the app store's set up but I understand that it's an edge case and this is the way I've got to navigate it so hey ho yeah but I shipped an update right it was bug fixes and and tweaks but hey you know I'm back in the game yeah

        Daniel (27:36)
        nice. Congratulations.

        David Gary Wood (27:39)
        So I have an update that I need to do for one of my other apps, Focus. So that will definitely be a thing I pick up over this next week or two. And that's a small update as well. So.

        Daniel (27:51)
        Did

        you put bug fixes and improvements into the release notes?

        David Gary Wood (27:55)
        I think Bugfix has made it. I'm not sure I went with improvements after it. I think I mentioned the iPad bit, but yeah, yeah. And it's quite sweet because I have a Govj group on Instagram. So I was able to go back to my little group and say, Hey, there's a new update. And you know, people have checked it out. Obviously not that much different to before really. But yeah.

        back in the back in the groove and it feels nice. That's good. Good to be shipping updates again. So. ⁓ what they want, I do not have time for, But yeah, slice by slice. And yeah, that's that's kind of my my little world at the moment.

        Daniel (28:31)
        Make the people happy. Give them what they want.

        You

        Yeah, fair.

        David Gary Wood (28:48)
        Focus, the other app. It's going to be fun for somebody who needs it. That's my video switcher. And it sends video out from the device over the network using a protocol called NDI. Somebody reported that it's locked to 30 FPS on the output and they wanted 60. ⁓

        Daniel (29:10)
        Only 6 years.

        David Gary Wood (29:12)
        Yeah, there's no point going any higher. Everything else doesn't go that high on the subsystem. no, so that's like one line of code to make that configurable. But then a few more bits because I need to actually put in a settings screen so the users can actually say, hey, this is what I want. I'm going to go with just toggling between 30 or 60 FPS because yeah.

        People tell me if they need anything else. So yeah.

        Daniel (29:39)
        Why would they

        ever 130 though if 60 is available? I'm not, oh, okay, yeah, okay. I get that.

        David Gary Wood (29:44)
        Low bandwidth, low bandwidth. Yeah.

        Yeah. So it should, it should be a configurable thing. But you spoke about modular modules and decoupling and that side of things earlier. And one of the beauties of the approach I've still got in my apps is if I make that configurable, then I can actually bring that into GoVJ as well. So yeah.

        Daniel (30:09)
        Yeah, that's good. That's very good plan.

        David Gary Wood (30:11)
        still have my Lego bricks, all my Swift packages that have everything in.

        Daniel (30:14)
        Oh yeah,

        the Lego bricks. I remember. That's really sweet. Oh, I have another module example actually, or modular example, which is I want to have three features in the near future. One of them is we have these surveys, right? Where we have a page on our website that shows you like what is the current market share of iOS 16.3, for example.

        David Gary Wood (30:19)
        Yeah.

        Mm-hmm.

        Daniel (30:44)
        among all iPhones and iPads. These are not interactive right now, but I kind of would like to make them interactive. Second is I would like people to be able to share their insights and charts, like get something out of telemetry deck, share that to the world, like as in a link.

        David Gary Wood (30:58)
        Mm-hmm.

        Daniel (31:03)
        and third, I bought a thing I ordered in January. I everyone, all the podcasters were talking about a thing called the terminal, the terminal like TRM and L I think, and I have one now. hang on. Like, me get it for you.

        David Gary Wood (31:19)
        See?

        Daniel (31:21)
        This is great podcasting. This is fantastic podcasting. So this is a tiny E Ink screen. I thought it would be like a 14 inch monitor or something, but it's more like a book page or something. It is a tiny E Ink screen.

        David Gary Wood (31:23)
        It is. It is. Okay.

        Cute. Bring it to the middle so I can just see

        the more of it. Yeah, there we go.

        Daniel (31:40)
        And it has Wi-Fi and you go to a website and you configure different integrations. And then it will update every hour or so with one of those integrations. And I kind of bought it because I want to see if it's easy to make a telemetry deck ⁓ plugin for it. And it seems like it should be very easy. Yeah, it's like use trmnl.com.

        David Gary Wood (31:46)
        Okay.

        Yeah. What's it called again? It's the terminal. TRMNL.

        Daniel (32:03)
        And like to just be able to like every now and then it switches to a chart of the newest users you have or whatever. And to do that, I need to be able to run queries, to run a specific query without direct like cookie-based authentication. And also to share charts on the internet, I kind of need to be able to run a query without direct cookie-based authentication, just that query, of course.

        And also to have interactive surveys, need to be able to run a query without direct authentication. also, on all three settings, need to very closely set exactly what I want people to be able to do and also cache it very heavily so that they don't play havoc with my fun new performance optimized service.

        And so that's what I mean, because I kind of waited until I had all these use cases together. And now I can hopefully, I can build a very slim implementation that still like where you can just like, just do some sharing at the beginning, but it leaves the door open for, okay, do I have like, I'm not closing the door towards, I don't know, users can send additional filters that will be layered on top of the existing filter, but they can't take a filter away because I want...

        David Gary Wood (33:23)
        Yes.

        Daniel (33:23)
        I

        don't want to expose them to any data or I don't know. And so another example of here modularizing stuff and whatever.

        David Gary Wood (33:32)
        nuts I'm just reading back the thing as well the device itself charges every three months that's that's very cool if you get all of this pulled together I would definitely want my charts on there like I'm looking at that and going ⁓ that's a Christmas present maybe later this year or something

        Daniel (33:38)
        Yep, pretty much. Because it is so... Yeah.

        Yeah.

        Yeah. I mean,

        it's a nice, it's a fantastic idea because all the rendering happens on their servers. So the thing just like pulls down a new image every few hours and displays that and it doesn't do anything else and it's E Ink so it doesn't need any like power to display stuff. So it's very genius. The only thing that I'm very aware of is as soon as this company goes out of business,

        David Gary Wood (34:01)
        Mm-hmm.

        Daniel (34:15)
        as most new startups do, like this thing is completely useless. Unless they, there's a developer mode and I think I paid the extra 10 bucks or so to be in the developer mode. So maybe that will enable me to do more. But yeah, that's just the way it is. But I think it's still very nice. You probably can build such a thing yourself, but I'm just not a big hardware builder. I like the fact that this is just a thing.

        David Gary Wood (34:16)
        Mm-hmm.

        Yeah.

        Yeah, that's.

        Daniel (34:39)
        an item. And you can either stand it up or hang it on the wall.

        David Gary Wood (34:40)
        Yeah, I have to really want to build us something.

        For hardware, I have to really want to build it to get into it. Otherwise, I'm the same as you. I just want a thing to work.

        Daniel (34:50)
        Yeah. I have this buddy who has

        for some reason hundreds of these little E displays that are used as price tags by supermarkets and IKEA and stuff. every now and then he's like, hey, do you want a few of those little E Ink displays that are used as price tags in IKEA and stuff? And I'm always like, no, what would I do with them? I don't want another project. I have projects. I have way too many projects.

        David Gary Wood (34:59)
        You

        Hehehehehe

        Yes. ⁓

        mate, yeah, cause you, it's like the, the Star Wars Admiral Ackbar meme, right? It's a trap.

        Daniel (35:25)
        Yeah, pretty much.

        David Gary Wood (35:26)
        But I think you have nerds knight me slightly with that. I'm looking at that and I'm like, I'd love one of those.

        Daniel (35:33)
        And that's how

        it goes. Like you hear about it in a podcast and then you buy one and now you have to have another podcast so it can tell people about it. Because you heard about it, like you Dave heard about it in this podcast.

        David Gary Wood (35:42)
        We need, we need,

        Yeah, and they're not sponsoring us. Maybe that's something that we should figure out.

        Daniel (35:48)
        They are, that is like

        incredibly rude of them that they are not sponsoring us right now. They should like, they should totally send each of us, just another one, like one to New Zealand, another one to Germany. I waited like months for this thing because they were kind of back ordered.

        David Gary Wood (36:03)
        Yeah.

        Well, if anybody knows anybody over there, then definitely hook me up because I'd be interested to see. But yeah, we were looking for sponsors at one point for the show, but I think it's fair to say we do it for the love of doing the show. you know, ⁓ that's it for the passion. ⁓ But on the. No, we're not.

        Daniel (36:19)
        For the love of God, Dave, let's just do the show. For the passion. And we're also not sponsored by cigarettes, by the way.

        David Gary Wood (36:32)
        We're absolutely not.

        However, Daniel, I need to get on with some chores. I have to go and take my car to be tested for road safety. So wish me luck. It's going to be busy.

        Daniel (36:44)
        Fantastic. That's a good chore. Right.

        Everyone else has probably finished their chores. If you haven't finished your chore, you can totally stop it right there because you don't need to finish all the chores. You can just like, I don't know, like make progress on them. Good for you. Like if you want, send us a selfie on our Mastodon account and we will be super happy for you and proud.

        David Gary Wood (37:09)
        Absolutely. And maybe I'll take a selfie when I'm doing my tour, Daniel, and kick the whole thing off. ⁓

        Daniel (37:10)
        Right.

        Fantastic. I cleaned

        my bike today, but I forgot I didn't take a selfie. I will do that next time.

        David Gary Wood (37:19)
        Excellent.

        Daniel (37:21)
        All right, fantastic. So everyone, thanks for listening. Please rate us on iTunes and the YouTube. Send us emails at contactedwaitingforeview.com. Send your chores and selfies to our Mastodon account, which Dave will tell you what that name is because I forgot the server.

        David Gary Wood (37:39)
        So I think we're on iOS dev.space and I do believe that it is. Let me find it. Right.

        Daniel (37:40)
        Right. Okay. Then I will just while you

        look it up, I will continue the outro, is join also also join our discord. The link is in the show notes and also send us email at contact at waiting for review.com. People can find me.

        David Gary Wood (37:56)
        So we are just waiting

        for review. Sorry, Daniel. I literally just found it. I'll interject. we are waiting for review at iosdev.space. And the reason I forgot is because we had an account elsewhere at one point and it was WFR podcast something, but forget that. It's just waiting for review at iosdev.space.

        Daniel (38:00)
        Yeah, do say.

        Fantastic.

        Fantastic. You can also mention us on the mastodons and we'll also see it. So you can find me at daniel at social.telemetrydeck.com, which is still growing strong and I'm really happy about it. And Dave, where can people find you? Just a tiny bit of verhaspeling here.

        David Gary Wood (38:22)
        Exactly.

        Yeah, the best place to check me out to be honest to see what I'm up to is definitely Instagram. So that is lightbeamapps.com on Instagram. And for everything else, you'll have to check the show notes. I keep mentioning show notes. Go check them. They're good. I write them.

        Daniel (38:51)
        Go check the show

        notes. Like your podcast. Like we are one of those podcasts that still have show notes, which is pretty cool.

        David Gary Wood (38:59)
        Mm-hmm and transcripts and yeah all the things but

        Daniel (39:03)
        and

        audio descriptions.

        David Gary Wood (39:06)
        pretty much. ⁓

        Daniel (39:07)
        which I do

        myself while I share charts.

        David Gary Wood (39:10)
        Exactly,

        you're very good at it. But on that note, Daniel, I will see you again soon.

        Daniel (39:18)
        You

        will, it has been a pleasure my friend.

        David Gary Wood (39:20)
        Yeah, lovely to be back on the air. So have a good day, mate.

        Daniel (39:26)
        you soon. Bye!


        """
    
    let dmlTranscriptionText: String = """
        WEBVTT

        NOTE
        Podcast: Dirty Minutes Left
        Episode: DML421 Valis
        Publishing Date: 2024-04-14T07:15:00+02:00
        Podcast URL: https://compendion.net/dirtyminutesleft
        Episode URL: https://compendion.net/dirtyminutesleft/421

        00:00:16.297 --> 00:00:23.197
        <v Holger Krupp>Herzlich Willkommen zu Folge Nummer 421 von der Demenz Lefley-Wahne.

        00:00:23.377 --> 00:00:28.917
        <v Arne ‚codenaga’ Ruddat>Hallo, lieber Holger. Hallo, liebe Hörende. Wir trinken heute The Sea Blue Edition Red Bull Juneberry.

        00:00:30.617 --> 00:00:34.077
        <v Holger Krupp>Genau. Schmeckt gar nicht so schlecht. Also schmeckt nicht wie Red Bull.

        00:00:34.297 --> 00:00:36.657
        <v Holger Krupp>Also nicht wie klassisches Red Bull.

        00:00:36.937 --> 00:00:39.237
        <v Holger Krupp>Hat 32 Milligramm pro 100 Milliliter Koffein.

        00:00:40.117 --> 00:00:43.017
        <v Holger Krupp>Juneberry kenne ich gar nicht. Das ist eine Felsenbirne.

        00:00:43.937 --> 00:00:46.537
        <v Arne ‚codenaga’ Ruddat>Felsenbirne, wer kennt sie nicht? Das ist halt ein nordamerikanisches Ding,

        00:00:46.597 --> 00:00:49.617
        <v Arne ‚codenaga’ Ruddat>deswegen gibt es ja keinen sinnvollen deutschen bekannten Namen für.

        00:00:50.777 --> 00:00:51.157
        <v Holger Krupp>Felsenbirne.

        00:00:51.417 --> 00:00:56.197
        <v Arne ‚codenaga’ Ruddat>Ja, klar. Natürlich, das hast du dir doch gerade... Nein, tatsächlich,

        00:00:56.317 --> 00:00:59.317
        <v Arne ‚codenaga’ Ruddat>ich kenne das so, heißt das Viech so, aber ich kenne das auch sonst nicht.

        00:01:00.237 --> 00:01:07.717
        <v Holger Krupp>Steht so auf der Verpackung drauf. Felsenbirne. Aber sieht gar nicht aus wie eine Birne.

        00:01:08.597 --> 00:01:11.097
        <v Arne ‚codenaga’ Ruddat>Wo steht denn auf dieser Verpackung hier Felsenbirne?

        00:01:11.097 --> 00:01:14.837
        <v Holger Krupp>Da steht in dem Energydrink mit dem Geschmack von Felsenbirne. Ach, tatsächlich.

        00:01:16.357 --> 00:01:16.717
        <v Arne ‚codenaga’ Ruddat>Felsenbirne.

        00:01:16.977 --> 00:01:18.677
        <v Holger Krupp>Das sieht aber auch nicht aus wie eine Birne.

        00:01:18.877 --> 00:01:19.237
        <v Arne ‚codenaga’ Ruddat>Nee.

        00:01:19.637 --> 00:01:23.117
        <v Holger Krupp>Das klingt wie den abgetüchtigen Kernobstgewächsende. Aber naja.

        00:01:23.537 --> 00:01:28.597
        <v Holger Krupp>Sieht eher aus wie so eine Blaubeere. Stimmt. Finde ich so von der...

        00:01:28.597 --> 00:01:30.297
        <v Arne ‚codenaga’ Ruddat>Es ist ja auch keine Beere, es ist ja eine Birne.

        00:01:30.957 --> 00:01:31.757
        <v Holger Krupp>Aber es sieht aus wie eine Beere.

        00:01:31.757 --> 00:01:33.197
        <v Arne ‚codenaga’ Ruddat>Ordnung der Rosenartigen übrigens.

        00:01:33.557 --> 00:01:38.677
        <v Holger Krupp>Äh, das ist mir auch egal. Genau, wir haben gespielt Walis von der Renovation Collection 1.

        00:01:39.357 --> 00:01:45.217
        <v Arne ‚codenaga’ Ruddat>Genau. Genau. Ich fand es, also es ist so ein Spiel, Anime-Stil und zwar der

        00:01:45.217 --> 00:01:49.877
        <v Arne ‚codenaga’ Ruddat>alte Anime-Stil, nicht der neuere, wo die Figuren alle viel größere Augen haben,

        00:01:49.937 --> 00:01:52.437
        <v Arne ‚codenaga’ Ruddat>sondern der ältere, wo sie noch einigermaßen menschlich aussahen.

        00:01:54.003 --> 00:01:56.963
        <v Arne ‚codenaga’ Ruddat>Und das Spiel ist ja auch relativ alt schon, aus den 90ern.

        00:01:58.423 --> 00:01:59.143
        <v Holger Krupp>Von Megadrive?

        00:01:59.803 --> 00:02:01.003
        <v Arne ‚codenaga’ Ruddat>Ach, von Megadrive, okay.

        00:02:01.403 --> 00:02:02.903
        <v Holger Krupp>Ich hab immer ein Megadrive-Spiel.

        00:02:03.183 --> 00:02:07.343
        <v Arne ‚codenaga’ Ruddat>Man spielt so ein Mädel, Yuno, ja, Yuko, glaube ich, heißt sie.

        00:02:08.063 --> 00:02:11.503
        <v Arne ‚codenaga’ Ruddat>Und die träumt irgendwie was und dann wundert sie sich über das Wetter und plötzlich

        00:02:11.503 --> 00:02:13.543
        <v Arne ‚codenaga’ Ruddat>ist sie in einer anderen Welt und muss alles platt hauen, was da ist.

        00:02:13.643 --> 00:02:14.823
        <v Holger Krupp>In der Fantasy-World.

        00:02:14.963 --> 00:02:20.143
        <v Arne ‚codenaga’ Ruddat>Es ist ein Sideways-Jump'n'Run quasi. Und sie hat ein Schwert in der Hand und

        00:02:20.143 --> 00:02:23.443
        <v Arne ‚codenaga’ Ruddat>kann halt irgendwie so einen Slide machen und mit dem Schwert hauen und springen.

        00:02:24.843 --> 00:02:28.983
        <v Holger Krupp>Das Schwert kann so schießen wie bei Zelda manchmal.

        00:02:29.423 --> 00:02:32.263
        <v Arne ‚codenaga’ Ruddat>Ja, aber das muss man erst einsammeln. Ich bin noch nicht so sicher,

        00:02:32.283 --> 00:02:34.103
        <v Arne ‚codenaga’ Ruddat>wie weit das geht. Ich habe es zwei Level lang gespielt.

        00:02:34.263 --> 00:02:36.983
        <v Arne ‚codenaga’ Ruddat>Das zweite Level sah völlig anders aus, wie das bei diesen Jump'n'Runs ja auch

        00:02:36.983 --> 00:02:39.763
        <v Arne ‚codenaga’ Ruddat>üblich ist, dass die zweite Welt dann einfach anders aussieht als die erste.

        00:02:40.123 --> 00:02:41.623
        <v Holger Krupp>Die sehen alle anders aus tatsächlich.

        00:02:41.883 --> 00:02:46.163
        <v Arne ‚codenaga’ Ruddat>Gehe ich auch von aus, ja. Damit man auch was sieht über die Dauer des Spiels

        00:02:46.163 --> 00:02:51.583
        <v Arne ‚codenaga’ Ruddat>und vor seinen FreundInnen angeben kann, sagen, hey, warst du schon in der Lava-Welt?

        00:02:51.663 --> 00:02:53.703
        <v Arne ‚codenaga’ Ruddat>Und du so, was? Was? Es gibt eine Lava-Welt? Ja.

        00:02:54.823 --> 00:02:59.443
        <v Arne ‚codenaga’ Ruddat>Und was mir bei diesem Spiel aufgefallen ist, ist, dass es unfassbar lahm ist.

        00:03:00.303 --> 00:03:01.783
        <v Arne ‚codenaga’ Ruddat>Hast du das auch so bemerkt?

        00:03:02.063 --> 00:03:08.163
        <v Holger Krupp>Ja, also das Spiel hat ein paar Probleme. Zum einen die Zwischensequenzen, die dort kommen.

        00:03:08.423 --> 00:03:09.983
        <v Holger Krupp>Das ist dann halt immer so ein Bild,

        00:03:10.103 --> 00:03:13.383
        <v Holger Krupp>was sich da so ein bisschen hinterher wechselt. Und dann ist da Text.

        00:03:14.043 --> 00:03:17.923
        <v Holger Krupp>Und das ist halt super lange, lahm. Und es ist schlecht übersetzt.

        00:03:18.043 --> 00:03:22.583
        <v Holger Krupp>Also es gibt einige Englisch-Fehler. also man merkt, dass es halt aus dem Japanischen

        00:03:22.583 --> 00:03:26.743
        <v Holger Krupp>ins Englisch übersetzt wurde und das nicht korrekt und also man drückt eine

        00:03:26.743 --> 00:03:30.503
        <v Holger Krupp>Taste und dann läuft der Text ein bisschen weiter und dann hört der irgendwann auf

        00:03:30.923 --> 00:03:33.803
        <v Holger Krupp>und dann drückt man eine Taste und dann geht es weiter und das ist halt mitten

        00:03:33.803 --> 00:03:38.503
        <v Holger Krupp>im Satz, also das passt da, wo der Text quasi aufhört, im Englischen absolut

        00:03:38.503 --> 00:03:43.143
        <v Holger Krupp>nicht hin, diese Pause, diese Gedankenpause, wenn man das eine Gedankenpause nennen möchte.

        00:03:44.443 --> 00:03:48.223
        <v Holger Krupp>Auch das, also das ist erstmal super langsam und man kann es halt nicht abbrechen,

        00:03:48.223 --> 00:03:51.403
        <v Holger Krupp>Man muss halt ewig lange sich diesen Text durchlesen.

        00:03:51.403 --> 00:03:53.703
        <v Arne ‚codenaga’ Ruddat>Ich habe es auch nicht geschafft, das zu beschleunigen. Also ich habe es irgendwann

        00:03:53.703 --> 00:03:56.203
        <v Arne ‚codenaga’ Ruddat>geschafft, das abzubrechen tatsächlich. Ich weiß aber nicht genau wie.

        00:03:56.803 --> 00:03:58.663
        <v Arne ‚codenaga’ Ruddat>Vielleicht war es auch einfach vorbei mitten im Satz.

        00:03:59.043 --> 00:04:00.643
        <v Holger Krupp>Beschleunigen geht halt auch nicht. Man kann es nicht beschleunigen.

        00:04:00.763 --> 00:04:01.843
        <v Arne ‚codenaga’ Ruddat>Genau, man kann es nicht beschleunigen.

        00:04:01.863 --> 00:04:04.643
        <v Holger Krupp>Das Einzige, was man machen kann, ist halt diese Gedankenpausen überspringen,

        00:04:04.663 --> 00:04:09.283
        <v Holger Krupp>indem man immer, immer, immer wieder AAA drückt, sodass diese Gedankenpause übersprungen wird.

        00:04:12.566 --> 00:04:15.526
        <v Holger Krupp>Und auch das Gehen der Figur ist halt auch super langsam.

        00:04:15.766 --> 00:04:18.746
        <v Arne ‚codenaga’ Ruddat>Ich würde das Spiel gerne in doppelter Geschwindigkeit spielen.

        00:04:18.846 --> 00:04:21.446
        <v Arne ‚codenaga’ Ruddat>Ich glaube, das kommt dem ganz gut nahe, was man eigentlich möchte.

        00:04:21.806 --> 00:04:26.506
        <v Holger Krupp>Was mir an diesem Spiel auch nicht gefallen hat, also das erste Level,

        00:04:26.646 --> 00:04:32.846
        <v Holger Krupp>da hat die Figur, die man da spielt, so eine Schulmädchen-Uniform aus Japan an.

        00:04:33.786 --> 00:04:38.226
        <v Holger Krupp>Ich würde sagen, das ist relativ normal. Und dann kommt sie in der Zwischensequenz,

        00:04:38.306 --> 00:04:45.626
        <v Holger Krupp>kommt auf diese Figur, Himmelsfigur da, die sie da fragte, ob sie helfen möchte.

        00:04:45.846 --> 00:04:48.626
        <v Holger Krupp>Und dann sagt das Schmulmädchen, nein, will ich nicht.

        00:04:48.786 --> 00:04:56.046
        <v Holger Krupp>Und dann verwandelt diese Figur sie in eine Kriegerin mit nur einem BH an,

        00:04:56.166 --> 00:04:58.486
        <v Holger Krupp>so einem Metall-BH, kurzem Rock

        00:04:58.486 --> 00:05:01.886
        <v Holger Krupp>und so, wo du denkst, das ist heute ein bisschen wieder viel Sexismus.

        00:05:02.066 --> 00:05:03.786
        <v Holger Krupp>Das muss ja jetzt eigentlich auch nicht sein.

        00:05:04.486 --> 00:05:10.746
        <v Holger Krupp>Ist halt nur eine Anime-Figur und bla bla bla, aber das hätte ja nicht unbedingt sein müssen.

        00:05:11.966 --> 00:05:17.026
        <v Holger Krupp>Aber das ist halt der Stil von damals. Ja, also das Spiel ist,

        00:05:17.046 --> 00:05:19.266
        <v Holger Krupp>finde ich, eigentlich macht das Spaß.

        00:05:19.546 --> 00:05:21.966
        <v Arne ‚codenaga’ Ruddat>Finde ich auch tatsächlich. Eigentlich ist es ein ganz okayes Spiel.

        00:05:22.046 --> 00:05:25.706
        <v Arne ‚codenaga’ Ruddat>Es ist halt super lahm und man muss halt damit klarkommen, dass es so alt ist

        00:05:25.706 --> 00:05:27.686
        <v Arne ‚codenaga’ Ruddat>und die ganzen althergebrachten Dinge so macht.

        00:05:28.246 --> 00:05:31.686
        <v Arne ‚codenaga’ Ruddat>Eigentlich ist es okay. Was mich tatsächlich ein bisschen stört,

        00:05:31.746 --> 00:05:38.246
        <v Arne ‚codenaga’ Ruddat>und das hätte ich in der Programmierstube auch erzählt, es gibt so wenig Möglichkeiten, sich zu entscheiden.

        00:05:38.646 --> 00:05:43.926
        <v Arne ‚codenaga’ Ruddat>Man findet irgendwie in den ersten zwei Leveln, findet man drei Schwert-Upgrades und dann hat man die.

        00:05:44.026 --> 00:05:47.246
        <v Arne ‚codenaga’ Ruddat>Und man verliert die auch nicht, wenn man getroffen wird, sondern man hat die dann einfach.

        00:05:47.426 --> 00:05:49.966
        <v Arne ‚codenaga’ Ruddat>Ich habe keine Ahnung, ob es noch irgendwie weitergeht, ob sich das Schwert

        00:05:49.966 --> 00:05:52.266
        <v Arne ‚codenaga’ Ruddat>noch irgendwie weiterentwickelt, ob man das irgendwie verliert oder so.

        00:05:52.826 --> 00:05:58.066
        <v Arne ‚codenaga’ Ruddat>Aber wenn in den ersten zwei Leveln schon quasi das komplette Repertoire der Figur klar ist.

        00:05:58.646 --> 00:06:02.026
        <v Holger Krupp>Nein, es gibt verschiedene Waffen. Also du kannst verschiedene Waffen bekommen.

        00:06:02.646 --> 00:06:06.706
        <v Holger Krupp>Und was halt auch nervig ist, in einigen späteren Leveln, die sind ein bisschen...

        00:06:07.712 --> 00:06:11.852
        <v Holger Krupp>verwirrend, wo man lang gehen muss. Das muss hin und zurück gehen und so.

        00:06:12.252 --> 00:06:15.732
        <v Holger Krupp>Was mich noch gestört hat, ist, man kann ja diesen Slide, hast du ja schon angesprochen,

        00:06:15.732 --> 00:06:17.212
        <v Holger Krupp>machen, dass man so ein bisschen rutscht.

        00:06:17.692 --> 00:06:22.592
        <v Holger Krupp>Bei vielen Spielen ist dieses Rutschen dann auch eine Zeit, wo man unbesiegbar

        00:06:22.592 --> 00:06:24.872
        <v Holger Krupp>ist, sodass man unter einem Gegner durchrutschen kann oder sowas.

        00:06:25.592 --> 00:06:28.292
        <v Holger Krupp>Und das ist hier nicht der Fall. Man kann halt bei diesem Rutschen getroffen

        00:06:28.292 --> 00:06:30.312
        <v Holger Krupp>werden. Das finde ich halt auch ein bisschen nervig.

        00:06:30.932 --> 00:06:34.912
        <v Holger Krupp>Die Sprünge, also gerade, ich glaube, Level 3 oder Level 4 war das,

        00:06:34.932 --> 00:06:39.512
        <v Holger Krupp>so eine Lava-Welt. da waren viele kleine Sprünge, die man machen musste.

        00:06:40.132 --> 00:06:43.592
        <v Holger Krupp>Und die fand ich immer nicht so sehr einfach. Da bin ich sehr häufig ganz ein

        00:06:43.592 --> 00:06:47.612
        <v Holger Krupp>bisschen zu kurz gesprungen und dann immer wieder runtergefallen und musste

        00:06:47.612 --> 00:06:49.152
        <v Holger Krupp>alles zurück und nochmal neu laufen.

        00:06:49.432 --> 00:06:56.072
        <v Holger Krupp>Bis mir dann aufgefallen ist, dass man mit diesem Slide über so kleine Abgründe hinweg sliden kann.

        00:06:56.292 --> 00:06:58.552
        <v Holger Krupp>Dann war das halt deutlich einfacher.

        00:06:58.872 --> 00:07:01.212
        <v Holger Krupp>Aber das muss man halt auch erstmal verstehen.

        00:07:02.372 --> 00:07:06.772
        <v Holger Krupp>Und ja, das waren halt so die Probleme, Probleme, auf die ich dort gestoßen bin bei diesem Spiel.

        00:07:06.932 --> 00:07:09.852
        <v Arne ‚codenaga’ Ruddat>Und was mich grundsätzlich auch bei allen Jump'n'Runs stört,

        00:07:09.952 --> 00:07:13.432
        <v Arne ‚codenaga’ Ruddat>wenn man so einen Mario Jump'n'Run spielt und man fängt an zu laufen,

        00:07:13.592 --> 00:07:17.692
        <v Arne ‚codenaga’ Ruddat>dann ist Mario auf der linken Seite des Bildschirms, wenn man nach rechts läuft.

        00:07:17.852 --> 00:07:22.992
        <v Arne ‚codenaga’ Ruddat>Und man sieht sehr viel von dem, was vor einem ist. Bei diesem Spiel ist es einfach andersrum.

        00:07:23.092 --> 00:07:27.132
        <v Arne ‚codenaga’ Ruddat>Wenn man anfängt zu laufen, dann befindet man sich auf zwei Dritteln auf der

        00:07:27.132 --> 00:07:32.472
        <v Arne ‚codenaga’ Ruddat>rechten Seite, also hinter der Mitte und hat quasi nur ein Drittel des Bildschirms

        00:07:32.472 --> 00:07:33.832
        <v Arne ‚codenaga’ Ruddat>vor sich, während man geht.

        00:07:34.232 --> 00:07:37.892
        <v Arne ‚codenaga’ Ruddat>Und dann tauchen da selbstverständlich sehr überraschend ständig irgendwelche

        00:07:37.892 --> 00:07:40.672
        <v Arne ‚codenaga’ Ruddat>Gegner auf, weil man einfach nur einen halben Meter weit gucken kann.

        00:07:41.592 --> 00:07:45.072
        <v Arne ‚codenaga’ Ruddat>Das nervt mich bei Spielen. Warum stellt man die Figur dann nicht an die linke

        00:07:45.072 --> 00:07:47.472
        <v Arne ‚codenaga’ Ruddat>Seite und lässt sie nach rechts laufen?

        00:07:47.632 --> 00:07:50.272
        <v Arne ‚codenaga’ Ruddat>Und dann hat man viel mehr Zeit, auf irgendwas zu reagieren.

        00:07:50.312 --> 00:07:53.212
        <v Arne ‚codenaga’ Ruddat>Das ist einfach fairer, als wenn dann plötzlich irgendwo Gegner auftauchen,

        00:07:53.952 --> 00:07:55.452
        <v Arne ‚codenaga’ Ruddat>die man einfach nicht gesehen hat.

        00:07:55.512 --> 00:07:58.492
        <v Arne ‚codenaga’ Ruddat>Wo man beim zweiten Spiel dann weiß, ah ja, da kommt gleich ein Gegner, dann weiß ich das jetzt.

        00:07:58.732 --> 00:08:01.872
        <v Arne ‚codenaga’ Ruddat>Und beim ersten Spiel halt so, oh nein, jetzt bin ich schon wieder überrascht

        00:08:01.872 --> 00:08:02.912
        <v Arne ‚codenaga’ Ruddat>von irgendwas getroffen.

        00:08:04.312 --> 00:08:06.712
        <v Arne ‚codenaga’ Ruddat>Das ist einfach schlechtes Spieldesign Ja,

        00:08:09.192 --> 00:08:13.352
        <v Arne ‚codenaga’ Ruddat>Insgesamt, wie gesagt, ist es okay Ich bin gespannt, es gibt ja noch Nachfolger

        00:08:13.352 --> 00:08:18.112
        <v Arne ‚codenaga’ Ruddat>von diesem Spiel, wie die sich so benehmen Ist jetzt kein Spiel was ich total

        00:08:18.112 --> 00:08:21.232
        <v Arne ‚codenaga’ Ruddat>furchtbar finde Ich könnte mir vorstellen, dass ich das irgendwann durchspiele

        00:08:21.232 --> 00:08:22.532
        <v Arne ‚codenaga’ Ruddat>Das dürfte auch nicht allzu lange dauern.

        00:08:23.432 --> 00:08:28.112
        <v Holger Krupp>Da musst du mal in meiner App nachgucken, weil in meiner App sind jetzt Playtimes

        00:08:28.112 --> 00:08:31.552
        <v Holger Krupp>drin, hab ich doch gar nicht erzählt Das sind jetzt die Spielzeiten drin und

        00:08:31.552 --> 00:08:35.752
        <v Holger Krupp>wenn du das eingetragen hast, dieses Spiel in der App, dann könntest du unter,

        00:08:37.312 --> 00:08:40.112
        <v Holger Krupp>Warles suchen, war das Fantasy Soldier?

        00:08:40.292 --> 00:08:44.112
        <v Holger Krupp>Und da sagt er, eine Stunde bis eine Stunde, 100% dauert eine Stunde.

        00:08:45.432 --> 00:08:48.412
        <v Holger Krupp>Ich würde vermuten, ungefähr eine Stunde dauert das Spiel.

        00:08:48.672 --> 00:08:51.752
        <v Arne ‚codenaga’ Ruddat>Ja, könnte ich mir auch vorstellen. Ich würde auch vermuten tatsächlich,

        00:08:51.932 --> 00:08:56.992
        <v Arne ‚codenaga’ Ruddat>dass es 100% hier einfach nicht gibt, de facto, weil es so wenig Entscheidungsmöglichkeiten gibt.

        00:08:58.232 --> 00:08:58.712
        <v Holger Krupp>Ja.

        00:08:59.972 --> 00:09:05.072
        <v Arne ‚codenaga’ Ruddat>Naja, also wie gesagt, Es ist halt so ein okayes Spiel. Als Kind hätte ich das

        00:09:05.072 --> 00:09:05.872
        <v Arne ‚codenaga’ Ruddat>wahrscheinlich gut gefunden.

        00:09:07.558 --> 00:09:14.478
        <v Holger Krupp>Genau, es gibt ein Dreier-Collection, Walis-Collection 3 als Re- Re-Master,

        00:09:14.578 --> 00:09:19.278
        <v Holger Krupp>nicht Re-Master, ist das nicht, wie heißt das, Re-Print in drei durchsichtigen

        00:09:19.278 --> 00:09:21.758
        <v Holger Krupp>Cartridges für 150 Euro.

        00:09:22.218 --> 00:09:25.698
        <v Arne ‚codenaga’ Ruddat>Ja, auf dieser Cartridge ist auch der dritte Teil tatsächlich mit drauf.

        00:09:26.078 --> 00:09:29.918
        <v Holger Krupp>Der zweite nicht und es gibt noch einen Super-Walis für den Super Nintendo, offensichtlich.

        00:09:30.238 --> 00:09:32.618
        <v Arne ‚codenaga’ Ruddat>Das ist bestimmt das gleiche wie bei einem Super Nintendo.

        00:09:34.178 --> 00:09:36.138
        <v Holger Krupp>Das weiß ich nicht. Mal gucken.

        00:09:37.938 --> 00:09:39.758
        <v Arne ‚codenaga’ Ruddat>Naja. Was spielen wir denn nächstes Mal?

        00:09:40.078 --> 00:09:47.118
        <v Holger Krupp>Super Valis 4. Also das ist ein anderer Titel. Als nächstes spielen wir Awesome Golf.

        00:09:47.378 --> 00:09:49.698
        <v Holger Krupp>Das ist ein Spiel für den Atari Lynx.

        00:09:50.278 --> 00:09:54.218
        <v Holger Krupp>Ich kann ja jetzt Atari Lynx Spiele spielen auf meinem Analog Pocket,

        00:09:54.398 --> 00:09:58.758
        <v Holger Krupp>aber ich habe keine Atari Lynx Spiele, sondern nur die, die auf der Evercade

        00:09:58.758 --> 00:10:01.178
        <v Holger Krupp>Cartridge Collection Dingsbums drauf sind.

        00:10:01.318 --> 00:10:04.458
        <v Holger Krupp>Und da ist es nämlich auf der Atari Lynx Collection 1 drauf.

        00:10:04.798 --> 00:10:09.178
        <v Arne ‚codenaga’ Ruddat>Okay. Wunderbar. dann haben wir das geklärt. Nächstes Mal außerdem reden wir

        00:10:09.178 --> 00:10:11.978
        <v Arne ‚codenaga’ Ruddat>über den Bond-Film Leben und Sterben Lassen.

        00:10:13.098 --> 00:10:16.458
        <v Arne ‚codenaga’ Ruddat>Das dürfte der achte James-Bond-Film sein.

        00:10:16.778 --> 00:10:17.598
        <v Holger Krupp>Live and Let Die.

        00:10:18.858 --> 00:10:22.038
        <v Arne ‚codenaga’ Ruddat>An den habe ich gute Erinnerungen. Ich bin gespannt, wie der sich gehalten hat.

        00:10:24.438 --> 00:10:29.418
        <v Arne ‚codenaga’ Ruddat>So. Ich bin neulich auf was gestoßen, was ich sowohl erschütternd,

        00:10:29.418 --> 00:10:31.558
        <v Arne ‚codenaga’ Ruddat>wie auch gut, wie auch gruselig fand.

        00:10:31.818 --> 00:10:37.018
        <v Arne ‚codenaga’ Ruddat>Nämlich ein Video von Sabine Horstenfelder bei YouTube, wurde mir einfach so vorgeschlagen.

        00:10:37.098 --> 00:10:43.698
        <v Arne ‚codenaga’ Ruddat>Und zwar erzählt sie, wie sie aus der wissenschaftlichen Hochschulwelt quasi.

        00:10:45.078 --> 00:10:48.998
        <v Arne ‚codenaga’ Ruddat>Rausgegangen ist, weil sie unfassbar frustriert war, dass die nicht das gemacht

        00:10:48.998 --> 00:10:50.818
        <v Arne ‚codenaga’ Ruddat>haben, was sie dachte, dass sie machen würden.

        00:10:51.218 --> 00:10:54.718
        <v Arne ‚codenaga’ Ruddat>Nämlich wissenschaftliche, spannende Randgebietforschung.

        00:10:55.895 --> 00:10:58.915
        <v Arne ‚codenaga’ Ruddat>Machen die nämlich nicht, sondern die machen populärwissenschaftliche,

        00:10:59.015 --> 00:11:04.935
        <v Arne ‚codenaga’ Ruddat>populärforschung auf Themen, die so ein bisschen von dem abweichen, was man weiß,

        00:11:05.175 --> 00:11:11.875
        <v Arne ‚codenaga’ Ruddat>aber nicht wirklich, um Geld zu generieren, um weiter forschen zu können und ihre Leute zu bezahlen.

        00:11:11.875 --> 00:11:14.475
        <v Arne ‚codenaga’ Ruddat>Also, das liegt in diesem Video sehr nah. Wir verlinken das.

        00:11:15.295 --> 00:11:18.155
        <v Arne ‚codenaga’ Ruddat>Und da habe ich gedacht, ja, okay, die Frau hat offensichtlich einen anderen

        00:11:18.155 --> 00:11:21.755
        <v Arne ‚codenaga’ Ruddat>wissenschaftlichen Anspruch als manche andere Leute so.

        00:11:21.935 --> 00:11:25.915
        <v Arne ‚codenaga’ Ruddat>Und sie sagt auch, das ist ihre eigene Meinung. Und es gibt Leute in diesem,

        00:11:26.375 --> 00:11:27.895
        <v Arne ‚codenaga’ Ruddat>Wissenschaftsumfeld, die das sehr, sehr gut finden.

        00:11:28.095 --> 00:11:32.535
        <v Arne ‚codenaga’ Ruddat>Sie jedenfalls hat sich jetzt entschlossen, auch durch die Pandemie zu YouTube

        00:11:32.535 --> 00:11:36.015
        <v Arne ‚codenaga’ Ruddat>zu wechseln und das eben da alles zu machen, sich über Patreon finanzieren zu

        00:11:36.015 --> 00:11:37.055
        <v Arne ‚codenaga’ Ruddat>lassen und selbstständig zu werden.

        00:11:37.535 --> 00:11:39.835
        <v Arne ‚codenaga’ Ruddat>Und die hat spannende Videos. Ich habe noch ein anderes gefunden,

        00:11:39.995 --> 00:11:47.215
        <v Arne ‚codenaga’ Ruddat>wo sie wo sie sagt, dass der Klimawandel möglicherweise einfach noch viel schneller

        00:11:47.215 --> 00:11:50.635
        <v Arne ‚codenaga’ Ruddat>geht, als wir alle vermutet haben, was ja auch schon lange eine Befürchtung

        00:11:50.635 --> 00:11:51.695
        <v Arne ‚codenaga’ Ruddat>von vernünftigen Menschen ist.

        00:11:52.515 --> 00:11:59.515
        <v Arne ‚codenaga’ Ruddat>Und dass es in 20 Jahren schon an vielen Orten dieser Welt unlebbar sein kann, sowas wie Äquatornähe.

        00:11:59.595 --> 00:12:05.975
        <v Arne ‚codenaga’ Ruddat>Und dass es dann einfach auch Migrationen geben wird und Ausfälle von allem.

        00:12:05.975 --> 00:12:11.095
        <v Arne ‚codenaga’ Ruddat>nehmen und dass die Welt in 20 Jahren möglicherweise ganz anders aussieht als jetzt.

        00:12:12.215 --> 00:12:17.035
        <v Arne ‚codenaga’ Ruddat>Und das ist, ich finde das spannend, also sie hat natürlich verschiedene wissenschaftliche

        00:12:17.035 --> 00:12:21.335
        <v Arne ‚codenaga’ Ruddat>Ansätze für und belegt das auch alles, was sie so sagt und sagt auch selber,

        00:12:21.455 --> 00:12:25.295
        <v Arne ‚codenaga’ Ruddat>dass sie da jetzt gar nicht so zufrieden mit ist, mit dieser Erkenntnis und,

        00:12:25.775 --> 00:12:29.195
        <v Arne ‚codenaga’ Ruddat>ich werde da noch weiter gucken, was sie sonst so an wissenschaftlichen Dingen bringt.

        00:12:29.575 --> 00:12:32.655
        <v Arne ‚codenaga’ Ruddat>Ich mag ja so Wissenschafts-YouTube-Geschichten immer ganz gerne, muss ich sagen.

        00:12:33.095 --> 00:12:36.715
        <v Holger Krupp>Ja, ich finde die Frau, ich habe diese Videos von ein paar Jahren auch mal geguckt,

        00:12:36.735 --> 00:12:41.015
        <v Holger Krupp>was sie so gemacht hat, aber ich fand sie dann irgendwann doch sehr problematisch.

        00:12:41.915 --> 00:12:45.855
        <v Holger Krupp>Das war, glaube ich, ein Video über Klimawandel, wo sie gesagt hat,

        00:12:45.875 --> 00:12:48.515
        <v Holger Krupp>das ist alles gar nicht so schlimm. Das war, glaube ich, vor zwei, drei Jahren.

        00:12:48.875 --> 00:12:52.895
        <v Holger Krupp>Und ein Video, wo sie gesagt hat, der Atomkraft wird uns retten.

        00:12:52.935 --> 00:12:54.675
        <v Holger Krupp>Irgendwie sowas in der Art. Ich weiß es nicht mehr ganz genau.

        00:12:54.935 --> 00:12:58.095
        <v Holger Krupp>Also ich finde diese Frau problematisch.

        00:12:58.375 --> 00:12:59.475
        <v Holger Krupp>Sehr problematisch.

        00:13:02.284 --> 00:13:05.624
        <v Holger Krupp>Ich würde mich auch nicht unbedingt, also wenn du dir die Videos anguckst,

        00:13:05.624 --> 00:13:10.024
        <v Holger Krupp>würde ich mir mal eine zweite Meinung noch mal anholen, die aus einer anderen

        00:13:10.024 --> 00:13:10.764
        <v Holger Krupp>Richtung kommt vielleicht.

        00:13:10.864 --> 00:13:14.604
        <v Holger Krupp>Und dann selber überlegen, was man da, was da das Richtige ist.

        00:13:15.504 --> 00:13:18.744
        <v Arne ‚codenaga’ Ruddat>Okay. Ich habe bislang noch nichts Problematisches gefunden.

        00:13:18.944 --> 00:13:21.884
        <v Arne ‚codenaga’ Ruddat>Ich meine, sie ist halt Wissenschaftlerin, das heißt, sie hat jetzt wissenschaftliche

        00:13:21.884 --> 00:13:24.144
        <v Arne ‚codenaga’ Ruddat>Erkenntnisse. Das, was ich gerade gesagt habe über den Klimawandel,

        00:13:24.144 --> 00:13:26.744
        <v Arne ‚codenaga’ Ruddat>das Video, ist glaube ich jetzt zwei Monate alt.

        00:13:28.064 --> 00:13:32.004
        <v Arne ‚codenaga’ Ruddat>Und davor hat sie halt auch andere Sachen gemacht. auch andere Sachen gesagt,

        00:13:32.244 --> 00:13:36.464
        <v Arne ‚codenaga’ Ruddat>weil es gibt offensichtlich irgendwie 60 Klimamodelle und von diesen 60 Klimamodellen

        00:13:36.464 --> 00:13:40.464
        <v Arne ‚codenaga’ Ruddat>haben 10 gesagt, Temperaturen in 20 Jahren könnten erheblich höher sein als

        00:13:40.464 --> 00:13:41.404
        <v Arne ‚codenaga’ Ruddat>das, was ihr geglaubt habt.

        00:13:41.744 --> 00:13:48.724
        <v Arne ‚codenaga’ Ruddat>Die wurden dann aber als die Hot Models abgetan und ignoriert quasi bei der Prognose.

        00:13:49.484 --> 00:13:54.424
        <v Arne ‚codenaga’ Ruddat>Und jetzt gibt es halt berechtigte Vermutungen, dass genau diese 10 Modelle

        00:13:54.424 --> 00:13:55.604
        <v Arne ‚codenaga’ Ruddat>aber die richtigen sind.

        00:13:56.224 --> 00:14:01.384
        <v Arne ‚codenaga’ Ruddat>Und dass es einfach sehr viel heißer werden wird. so 5,5 Grad in 20 Jahren.

        00:14:01.504 --> 00:14:06.624
        <v Arne ‚codenaga’ Ruddat>Und mit der Erkenntnis macht sie dann halt verschiedene Prognosen, was passieren kann.

        00:14:07.604 --> 00:14:11.084
        <v Holger Krupp>Ja, wie gesagt, ich habe das jetzt nicht weiter hier vorbereitet,

        00:14:11.164 --> 00:14:15.224
        <v Holger Krupp>aber ich finde, diese Frau, weiß ich nicht, ich traue der nicht mehr.

        00:14:16.184 --> 00:14:18.744
        <v Arne ‚codenaga’ Ruddat>Interessant. Ja, ich wüsste gerne, warum, weil bislang hast du keinen Grund

        00:14:18.744 --> 00:14:24.864
        <v Arne ‚codenaga’ Ruddat>genannt, außer dass sie gesagt hat, hier, Atomkraft ist offensichtlich der Way to go.

        00:14:25.984 --> 00:14:30.064
        <v Holger Krupp>Ja, und sie Sie hatte auch, ich glaube, Zweifel am Klimawandel mal geäußert

        00:14:30.064 --> 00:14:33.504
        <v Holger Krupp>oder irgendwie sowas. Ich weiß es nicht mehr ganz genau. Das kann ich mir nicht vorstellen.

        00:14:33.584 --> 00:14:35.684
        <v Arne ‚codenaga’ Ruddat>Das hat sie jedenfalls in diesem Video definitiv nicht.

        00:14:37.304 --> 00:14:40.084
        <v Holger Krupp>Ich weiß. Wie gesagt, ich habe das Video jetzt nicht gesehen.

        00:14:40.184 --> 00:14:42.644
        <v Holger Krupp>Ich habe das erst heute gesehen, dass du das da reingeschrieben hast.

        00:14:43.184 --> 00:14:46.124
        <v Holger Krupp>Und hätte ich das gestern gesehen, dann hätte ich mich darauf vorbereitet.

        00:14:46.864 --> 00:14:48.444
        <v Holger Krupp>Das tut mir jetzt leid.

        00:14:48.524 --> 00:14:51.924
        <v Arne ‚codenaga’ Ruddat>Ja, liebe Hörende, wenn ihr da eine Meinung zu habt zu Sabine Hossenfelder,

        00:14:51.924 --> 00:14:52.764
        <v Arne ‚codenaga’ Ruddat>dann sagt doch mal Bescheid.

        00:14:54.149 --> 00:14:57.769
        <v Holger Krupp>Um dem Klimawandel entgegenzuwirken, fahre ich ja E-Auto.

        00:14:58.169 --> 00:15:01.109
        <v Holger Krupp>Aber E-Auto fahren ist ja trotzdem immer doof.

        00:15:01.349 --> 00:15:04.989
        <v Holger Krupp>Und deswegen möchte ich auch ein bisschen mehr Fahrrad fahren.

        00:15:05.229 --> 00:15:09.629
        <v Holger Krupp>Und habe jetzt ein E-Lastenrad. Da hatte ich ja schon mal berichtet von,

        00:15:09.709 --> 00:15:11.889
        <v Holger Krupp>dass ich das über das Firmleasing bekommen habe.

        00:15:13.609 --> 00:15:17.849
        <v Holger Krupp>Die Geschichte kann ich auch nicht nochmal erzählen, aber das Rad erstmal selber

        00:15:17.849 --> 00:15:24.109
        <v Holger Krupp>ist, ich habe so ein Cube Cargo Sport Dual Hybrid 1000 1000,

        00:15:24.109 --> 00:15:25.629
        <v Holger Krupp>bla bla, heißt das irgendwie, keine Ahnung.

        00:15:25.749 --> 00:15:27.109
        <v Arne ‚codenaga’ Ruddat>Das denkst du dir doch gerade aus.

        00:15:27.409 --> 00:15:34.429
        <v Holger Krupp>Nein, nein, das heißt tatsächlich, warte, das heißt Cube Cargo Dual Hybrid,

        00:15:35.889 --> 00:15:39.269
        <v Holger Krupp>ich weiß nicht, wo das Sport kommt, ob das Sport erst oder die 1000 erst kommt.

        00:15:39.549 --> 00:15:43.429
        <v Holger Krupp>Also, ja, Cube Cargo Sport Dual Hybrid 1000 heißt das.

        00:15:44.529 --> 00:15:49.609
        <v Holger Krupp>Okay. Das ist, ja, bekloppt. Ich wollte eigentlich lieber das ohne Sport haben.

        00:15:49.729 --> 00:15:54.209
        <v Holger Krupp>Das ohne Sport hat eine Namenschaltung und das mit Sport hat hat eine Kettenschaltung.

        00:15:54.309 --> 00:15:55.649
        <v Holger Krupp>Das war aber leider nicht verfügbar.

        00:15:57.229 --> 00:15:58.709
        <v Holger Krupp>Das ist jetzt auch nicht so schlimm.

        00:16:01.049 --> 00:16:03.569
        <v Holger Krupp>Das Rad ist super cool. Ich bin damit jetzt erst einmal gefahren.

        00:16:03.649 --> 00:16:06.749
        <v Holger Krupp>Ich bin also aus Altona damit bis nach Buxtehude gefahren.

        00:16:06.809 --> 00:16:11.769
        <v Holger Krupp>Mit der Fähre rüber nach Finkenwerder und dann von Finkenwerder aus ungefähr 20 Kilometer gefahren.

        00:16:12.489 --> 00:16:16.769
        <v Holger Krupp>Macht Spaß. Fährt sich so wie so ein Bus. Ich weiß nicht, ob du schon mal so

        00:16:16.769 --> 00:16:18.909
        <v Holger Krupp>einen langen Sprinter gefahren bist.

        00:16:20.149 --> 00:16:25.729
        <v Holger Krupp>So ähnlich fährt sich das. Man muss halt deutlich größere Wendekreise einplanen.

        00:16:25.749 --> 00:16:31.329
        <v Holger Krupp>Ich fahre ansonsten seit ungefähr 10 Jahren fast ausschließlich Rennräder.

        00:16:31.789 --> 00:16:34.209
        <v Holger Krupp>Und das ist halt ein komplett anderes Fahren.

        00:16:35.309 --> 00:16:41.649
        <v Holger Krupp>Zusätzlich ist das ja ein E-Bike, das heißt mit bis 25 kmh hat das einen Elektromotor,

        00:16:41.649 --> 00:16:43.409
        <v Holger Krupp>der das Ganze unterstützt.

        00:16:45.623 --> 00:16:51.303
        <v Holger Krupp>Das ist ganz nice, gerade so zum Anfahren. Aber ich bin über 30 gefahren und

        00:16:51.303 --> 00:16:53.583
        <v Holger Krupp>da kommt dann halt keine Unterstützung mehr.

        00:16:54.043 --> 00:17:00.063
        <v Holger Krupp>Also über 30 kmh kommt keine Unterstützung mehr. Und für 30 kmh ist das Fahrrad

        00:17:00.063 --> 00:17:02.103
        <v Holger Krupp>echt schwer. Also es wiegt über 50 Kilo.

        00:17:02.463 --> 00:17:05.243
        <v Holger Krupp>Und das fühlt sich lustig an.

        00:17:05.823 --> 00:17:10.883
        <v Holger Krupp>Macht halt Spaß zu fahren. Ich werde das nächste Mal meine Lütte da reinsetzen

        00:17:10.883 --> 00:17:16.983
        <v Holger Krupp>und dann mal gucken, wie sie damit umgeht. Das wird, glaube ich, ganz cool.

        00:17:17.483 --> 00:17:20.763
        <v Arne ‚codenaga’ Ruddat>Merkst du die Unterstützung bei diesem Fahrrad?

        00:17:21.263 --> 00:17:26.663
        <v Arne ‚codenaga’ Ruddat>Merkst du die aktiv oder hast du nur das Gefühl, es ist leichter zu fahren?

        00:17:27.163 --> 00:17:30.503
        <v Holger Krupp>Ja, also beim Anfahren gerade merkt man sie aktiv. Da merkt man richtig,

        00:17:30.563 --> 00:17:32.143
        <v Holger Krupp>wie das Ding beschleunigt. Okay.

        00:17:33.003 --> 00:17:40.183
        <v Holger Krupp>Aber irgendwann ist es halt leichter und knapp über 25 kmh merkt man halt auch,

        00:17:40.383 --> 00:17:42.903
        <v Holger Krupp>also die fährt so langsam auch dann auch zurück, die Unterstützung,

        00:17:43.083 --> 00:17:44.783
        <v Holger Krupp>wenn du an die Grenze kommst.

        00:17:45.623 --> 00:17:47.163
        <v Holger Krupp>Und man ist ja nicht mehr da.

        00:17:47.803 --> 00:17:48.303
        <v Arne ‚codenaga’ Ruddat>Okay.

        00:17:49.143 --> 00:17:54.543
        <v Holger Krupp>Man merkt jetzt kein abruptes, oh, jetzt ist die Unterstützung bei 25 kmh oder bei 26 kmh weg.

        00:17:54.703 --> 00:18:00.963
        <v Holger Krupp>Das geht schon smooth über in in Normalfahren.

        00:18:01.943 --> 00:18:06.743
        <v Holger Krupp>Aber ist halt schon, ist ein E-Bike halt.

        00:18:07.003 --> 00:18:13.843
        <v Arne ‚codenaga’ Ruddat>Ja. Ja. Ja, spannend. Ja, erzähl erst mal die Geschichte.

        00:18:14.063 --> 00:18:18.763
        <v Holger Krupp>Die Geschichte, wie ich das Fahrrad bekommen Wir haben ja ab Anfang März gab

        00:18:18.763 --> 00:18:19.743
        <v Holger Krupp>es dieses Fahrrad-Leasing.

        00:18:20.523 --> 00:18:24.483
        <v Holger Krupp>Und ich wusste das ungefähr schon eine Woche vorher. War dann schon beim Fahrradhändler,

        00:18:24.523 --> 00:18:26.583
        <v Holger Krupp>hab mir das Fahrrad schon ausgeruht, hab gesagt, ich will das haben,

        00:18:26.703 --> 00:18:29.423
        <v Holger Krupp>mit der Sitzbank, mit dem Regenverdeck.

        00:18:30.103 --> 00:18:33.323
        <v Holger Krupp>Und die Teile, die wir nicht in das Leasing packen können, aus welchen Gründen

        00:18:33.323 --> 00:18:36.083
        <v Holger Krupp>auch immer, die bezahle ich dann so. Das ist gar kein Problem.

        00:18:36.583 --> 00:18:39.503
        <v Holger Krupp>Ich weiß ja, die kosten jetzt nicht so viel verglichen mit dem Fahrrad.

        00:18:40.263 --> 00:18:44.903
        <v Holger Krupp>Dann meinte ich, ja, gar kein Problem. Problem, die Bank, die ist dann ab dem

        00:18:44.903 --> 00:18:46.423
        <v Holger Krupp>18.03. wieder lieferbar.

        00:18:47.003 --> 00:18:50.743
        <v Holger Krupp>Willst du das Fahrrad schon vorher mitnehmen? Oder willst du dann bis zum 18.03.

        00:18:50.823 --> 00:18:52.403
        <v Holger Krupp>warten? Ich sage, dann warte ich bis zum 18.03.

        00:18:52.703 --> 00:18:55.263
        <v Holger Krupp>Ja, okay, wir rufen dich dann ein, wenn die Bank dann da ist.

        00:18:56.003 --> 00:19:01.583
        <v Holger Krupp>So, dann, keine Ahnung, irgendwie 21.03. oder irgendwann kurz danach,

        00:19:01.703 --> 00:19:03.543
        <v Holger Krupp>eine Woche danach oder so, habe ich die angerufen und gesagt,

        00:19:03.603 --> 00:19:06.323
        <v Holger Krupp>ja, was ist das? Ja, die Bank ist Anfang April lieferbar.

        00:19:06.523 --> 00:19:08.383
        <v Holger Krupp>Ich sage, okay, warte ich halt bis Anfang April.

        00:19:09.243 --> 00:19:16.943
        <v Holger Krupp>Dann irgendwie Anfang April angerufen ja nee, die Bank ist ja erst Ende Juni lieferbar bitte was?

        00:19:17.683 --> 00:19:22.003
        <v Holger Krupp>ja, du kannst das Fahrrad ja aber schon mal abholen nee, ohne die Bank bringt

        00:19:22.003 --> 00:19:24.903
        <v Holger Krupp>mir das ja relativ wenig, ich will ja meine Lütte damit durch die Gegend fahren

        00:19:24.903 --> 00:19:29.803
        <v Holger Krupp>ja ja, dann musst du eben bis Ende Juni warten nein,

        00:19:30.563 --> 00:19:34.863
        <v Holger Krupp>wir machen das jetzt können wir bitte hier die Bank aus dem Leasing rausnehmen

        00:19:34.863 --> 00:19:38.663
        <v Holger Krupp>weil ich hab gesehen hier hier, ich google nebenbei, kann die jetzt hier sofort

        00:19:38.663 --> 00:19:41.643
        <v Holger Krupp>bestellen und kriege die übermorgen von einem anderen Fahrradhändler zugeschickt,

        00:19:41.663 --> 00:19:43.603
        <v Holger Krupp>diese Bank, kann ich dann auch selber da einbauen.

        00:19:44.567 --> 00:19:47.647
        <v Holger Krupp>Ja, nee, das geht ja jetzt nicht mehr. Wir haben das ja jetzt alles so.

        00:19:48.627 --> 00:19:51.527
        <v Holger Krupp>Also wir machen jetzt, bitte, wir nehmen diese Bank da raus.

        00:19:51.707 --> 00:19:54.947
        <v Holger Krupp>Nee, das musst du dann mit dem Leasing, mit der Leasingfirma besprechen.

        00:19:54.987 --> 00:19:56.247
        <v Holger Krupp>Da habe ich bei der Leasingfirma angerufen.

        00:19:56.687 --> 00:19:59.907
        <v Holger Krupp>Ja, einmal bitte hier diese Bank rausnehmen. Ja, nee, das geht nicht.

        00:20:00.167 --> 00:20:03.607
        <v Holger Krupp>Ja, okay, dann einmal bitte das Leasing stornieren und es kommt ein neues Angebot

        00:20:03.607 --> 00:20:04.427
        <v Holger Krupp>von einem Fahrradhändler.

        00:20:05.027 --> 00:20:08.067
        <v Holger Krupp>Ja, nee, das geht ja auch nicht, weil das wird ja jetzt schon abgebucht von

        00:20:08.067 --> 00:20:11.807
        <v Holger Krupp>deinem Gehalt in einem Monat oder so, in einem halben Monat.

        00:20:12.467 --> 00:20:14.987
        <v Holger Krupp>So, wie, das wird schon abgebucht? Ich habe das Fahrrad ja auch nicht mal bekommen.

        00:20:15.127 --> 00:20:16.587
        <v Holger Krupp>Wie kann das denn schon abgebucht werden?

        00:20:17.087 --> 00:20:19.667
        <v Holger Krupp>Und dann hat das irgendwie noch mal anderthalb Wochen gedauert,

        00:20:19.667 --> 00:20:21.827
        <v Holger Krupp>bis sie dieses Leasing rückgängig gemacht haben.

        00:20:22.487 --> 00:20:26.007
        <v Holger Krupp>Zwischenzeitlich hat mir der Fahrradhändler ein neues Angebot geschickt,

        00:20:26.007 --> 00:20:29.407
        <v Holger Krupp>ohne diese Bank und ohne das Regenverdeck.

        00:20:29.447 --> 00:20:31.087
        <v Holger Krupp>Das waren die beiden Teile, die lieferbar waren.

        00:20:32.027 --> 00:20:38.207
        <v Holger Krupp>Und dann, nachdem das dann endlich aus dem Leasing raus war und ich dann quasi

        00:20:38.207 --> 00:20:41.367
        <v Holger Krupp>ein neues Leasing abgeschlossen habe, konnte ich das abholen.

        00:20:41.407 --> 00:20:44.747
        <v Holger Krupp>Und dann habe ich zeitgleich, als ich wusste, es klappt, also als ich wusste,

        00:20:44.767 --> 00:20:50.107
        <v Holger Krupp>das alte Leasing ist storniert, habe ich bei einem Händler in Holland die Bank

        00:20:50.107 --> 00:20:55.247
        <v Holger Krupp>und das Verdeck bestellt und das kam zeitgleich mit dem Fahrrad quasi an.

        00:20:56.107 --> 00:20:59.327
        <v Holger Krupp>Und ey, ich hätte das Fahrrad quasi schon einen Monat vorher haben können,

        00:21:00.027 --> 00:21:04.027
        <v Holger Krupp>wenn entweder der Fahrradhändler mal drauf die Idee gekommen wäre,

        00:21:04.127 --> 00:21:07.367
        <v Holger Krupp>um selber mir vorzuschlagen, dass ich das einfach bei einem anderen Händler kaufe.

        00:21:08.847 --> 00:21:13.267
        <v Holger Krupp>Ja, oder, keine Ahnung. oder der Fahrradhändler mir einfach nichts angeboten

        00:21:13.267 --> 00:21:14.527
        <v Holger Krupp>hätte, was er selber nicht hat.

        00:21:15.407 --> 00:21:18.547
        <v Holger Krupp>Oder dieser Leasing an der Firma besser gewesen wäre.

        00:21:18.687 --> 00:21:22.307
        <v Arne ‚codenaga’ Ruddat>Ja, vor allem, dass du immer nachfragen musstest und dann erst erfahren hast,

        00:21:22.347 --> 00:21:25.827
        <v Arne ‚codenaga’ Ruddat>dass die Lieferung sich einfach um drei Monate verzögert. Das ist halt,

        00:21:27.124 --> 00:21:30.444
        <v Arne ‚codenaga’ Ruddat>Was ist denn das für eine Art? Ist ja wie bei Kickstarter.

        00:21:31.244 --> 00:21:34.744
        <v Arne ‚codenaga’ Ruddat>Hast du denn konkreten, also du hast ja jetzt offensichtlich dieses Angebot

        00:21:34.744 --> 00:21:38.964
        <v Arne ‚codenaga’ Ruddat>gekriegt, so einen Lastenfacher zu mieten, äh zu leasen und dann irgendwann zu übernehmen.

        00:21:39.024 --> 00:21:42.544
        <v Arne ‚codenaga’ Ruddat>Hast du einen konkreten Anwendungsfall im Kopf, wie du es benutzen willst?

        00:21:42.644 --> 00:21:45.744
        <v Arne ‚codenaga’ Ruddat>Willst du da deine Lörde reinschmeißen und dann einfach irgendwie an einen Löranleger

        00:21:45.744 --> 00:21:47.404
        <v Arne ‚codenaga’ Ruddat>fahren ins alte Land und gucken, was passiert?

        00:21:47.544 --> 00:21:52.684
        <v Arne ‚codenaga’ Ruddat>Oder mal gucken, was ist, jetzt hast du das und dann weißt du noch nicht so richtig.

        00:21:53.584 --> 00:22:00.284
        <v Holger Krupp>Ja, also ich will jetzt mit der kleinen, Radtouren machen und nach York fahren, überall wo hinfahren.

        00:22:00.724 --> 00:22:02.804
        <v Arne ‚codenaga’ Ruddat>Okay, also du hast keinen Plan. Mal gucken, was passiert.

        00:22:04.864 --> 00:22:07.544
        <v Holger Krupp>Wenn man sich ein Fahrrad kauft, dann fährt man mit dem Fahrrad rum.

        00:22:07.904 --> 00:22:11.584
        <v Holger Krupp>Aber ich habe jetzt nicht, übermorgen will ich damit da und da hinfahren.

        00:22:11.884 --> 00:22:16.204
        <v Holger Krupp>So einen Plan habe ich jetzt nicht. Aber wo ich jetzt vorher mit Fahrradanhänger

        00:22:16.204 --> 00:22:19.084
        <v Holger Krupp>an meinem Rennrad rumgefahren bin, würde ich jetzt mit dem Lastenrad fahren.

        00:22:19.824 --> 00:22:21.624
        <v Holger Krupp>Weil es halt einfach irgendwie cooler ist.

        00:22:23.004 --> 00:22:28.724
        <v Arne ‚codenaga’ Ruddat>Ja, prima. Spannende Zeiten. Ja. Auch spannende Zeiten gibt's bei,

        00:22:30.244 --> 00:22:35.044
        <v Arne ‚codenaga’ Ruddat>Blaze, beziehungsweise Evercade, denn die haben jetzt ein Software-Update herausgebracht

        00:22:35.044 --> 00:22:41.324
        <v Arne ‚codenaga’ Ruddat>für die Evercade-Versus-Konsole und das Evercade-EXP Handheld-System.

        00:22:42.404 --> 00:22:45.504
        <v Arne ‚codenaga’ Ruddat>Und zwar gibt's jetzt eine Library, das, was ich mir schon immer gewünscht habe,

        00:22:45.624 --> 00:22:50.164
        <v Arne ‚codenaga’ Ruddat>die nämlich sämtliche Evercade-Spiele einfach beinhaltet und da gibt's zu jedem

        00:22:50.164 --> 00:22:53.104
        <v Arne ‚codenaga’ Ruddat>ein Screenshot und eine kurze Beschreibung und das ist jetzt alles auf den Systemen drauf.

        00:22:53.344 --> 00:22:56.304
        <v Arne ‚codenaga’ Ruddat>Das heißt, man muss nicht mehr hinten in die Anleitung reingucken oder im Internet

        00:22:56.304 --> 00:22:59.164
        <v Arne ‚codenaga’ Ruddat>suchen, was es denn so gibt und wann die denn so erschienen sind,

        00:22:59.264 --> 00:23:02.384
        <v Arne ‚codenaga’ Ruddat>sondern kann das jetzt einfach innerhalb der Konsolen machen.

        00:23:03.044 --> 00:23:05.744
        <v Arne ‚codenaga’ Ruddat>Und man kann da auch seine eigenen reintun. Das funktioniert ganz einfach.

        00:23:05.844 --> 00:23:10.844
        <v Arne ‚codenaga’ Ruddat>Man steckt einfach das Modul in die Konsole und dann weiß sie, dass man das hat.

        00:23:12.619 --> 00:23:15.479
        <v Arne ‚codenaga’ Ruddat>Und ich finde das total super. Habe jetzt da erstmal angefangen,

        00:23:15.479 --> 00:23:16.839
        <v Arne ‚codenaga’ Ruddat>ein paar reinzustecken. Und mir ist

        00:23:16.839 --> 00:23:20.559
        <v Arne ‚codenaga’ Ruddat>aufgefallen, dass etliche von diesen Evercade-Cartridges Updates brauchen.

        00:23:21.939 --> 00:23:25.539
        <v Arne ‚codenaga’ Ruddat>Eine davon, da hat das Update nicht funktioniert. Also das sind irgendwelche

        00:23:25.539 --> 00:23:28.539
        <v Arne ‚codenaga’ Ruddat>Bugfixes wahrscheinlich. Es wird wohl kaum neue Features geben.

        00:23:30.299 --> 00:23:33.079
        <v Arne ‚codenaga’ Ruddat>Und ich finde das ziemlich gut. Hast du die Updates schon gemacht?

        00:23:33.539 --> 00:23:35.859
        <v Holger Krupp>Nein. Habe ich nie.

        00:23:37.219 --> 00:23:37.659
        <v Arne ‚codenaga’ Ruddat>Okay.

        00:23:38.079 --> 00:23:43.259
        <v Holger Krupp>Also ich weiß auch nicht. Also ich habe bei meiner App, wo ich sehe, welche Spiele ich habe.

        00:23:43.339 --> 00:23:46.839
        <v Holger Krupp>Also ich weiß nicht, was mir das bringt. Also ja, irgendwann werde ich das machen.

        00:23:46.899 --> 00:23:48.719
        <v Arne ‚codenaga’ Ruddat>Okay, dir nicht. Allen anderen Menschen bringt es halt was.

        00:23:49.279 --> 00:23:55.119
        <v Holger Krupp>Nee. Ich sehe jetzt einfach nicht den Sinn, dass ich da jetzt halt rein schwimmen

        00:23:55.119 --> 00:23:58.059
        <v Holger Krupp>muss, das reinzupacken. Ich weiß es aber auch nicht.

        00:23:58.599 --> 00:24:03.299
        <v Holger Krupp>Also vielleicht kannst du es mir erklären. Also ich habe dann auf der Konsole

        00:24:03.299 --> 00:24:04.559
        <v Holger Krupp>sehe ich dann, welche Spiele ich habe.

        00:24:05.059 --> 00:24:05.419
        <v Arne ‚codenaga’ Ruddat>Genau.

        00:24:05.759 --> 00:24:07.439
        <v Holger Krupp>Auch wenn die nicht eingelegt sind.

        00:24:07.819 --> 00:24:13.599
        <v Arne ‚codenaga’ Ruddat>Genau. Es gibt halt eine neue Library-Menüpunkt quasi und da siehst du alle Cartridges drin.

        00:24:14.039 --> 00:24:16.519
        <v Arne ‚codenaga’ Ruddat>Die, die du nicht hast, die sind halt ausgegraut und die, die du hast,

        00:24:16.639 --> 00:24:20.019
        <v Arne ‚codenaga’ Ruddat>die sind halt vollfarbig und da kannst du halt sehen, weil die rausgekommen sind.

        00:24:20.079 --> 00:24:22.959
        <v Arne ‚codenaga’ Ruddat>Du kannst, das finde ich tatsächlich am allerschönsten, du kannst die einfach

        00:24:22.959 --> 00:24:26.039
        <v Arne ‚codenaga’ Ruddat>sortieren nach Erscheinungsdatum.

        00:24:26.279 --> 00:24:29.239
        <v Arne ‚codenaga’ Ruddat>Dann siehst du genau, okay, bis zu dem Zeitpunkt habe ich alle,

        00:24:29.339 --> 00:24:30.659
        <v Arne ‚codenaga’ Ruddat>ab dem Zeitpunkt fehlen sie mir.

        00:24:30.799 --> 00:24:36.199
        <v Arne ‚codenaga’ Ruddat>Das sind also folgende, weil Pico Interactive Collection 4, habe ich ja keine

        00:24:36.199 --> 00:24:37.339
        <v Arne ‚codenaga’ Ruddat>Ahnung, welche Nummer die hat.

        00:24:37.499 --> 00:24:40.259
        <v Arne ‚codenaga’ Ruddat>Oder C64 Collection 3, weiß ich halt auch nicht.

        00:24:40.439 --> 00:24:43.899
        <v Arne ‚codenaga’ Ruddat>Juknukl, wann war die denn? Ist die jetzt dann rausgekommen oder vorher oder

        00:24:43.899 --> 00:24:45.159
        <v Arne ‚codenaga’ Ruddat>hinterher oder wie war es denn so?

        00:24:46.433 --> 00:24:48.933
        <v Arne ‚codenaga’ Ruddat>Und das kannst du dir jetzt einfach anzeigen lassen, sortieren lassen.

        00:24:49.053 --> 00:24:52.173
        <v Arne ‚codenaga’ Ruddat>Und dann siehst du genau, in welche Reihenfolge die erschienen sind.

        00:24:52.393 --> 00:24:53.933
        <v Arne ‚codenaga’ Ruddat>Und das finde ich tatsächlich sehr praktisch.

        00:24:55.233 --> 00:24:59.933
        <v Holger Krupp>Ja. Ja, kann praktisch sein, aber ich...

        00:25:01.993 --> 00:25:03.153
        <v Arne ‚codenaga’ Ruddat>Ja, gut, brauchst du nicht.

        00:25:03.233 --> 00:25:04.213
        <v Holger Krupp>Weil du hast dir die E-Mail geschrieben.

        00:25:04.413 --> 00:25:04.513
        <v Arne ‚codenaga’ Ruddat>Ja.

        00:25:05.073 --> 00:25:08.173
        <v Holger Krupp>Verstehe. Nein, aber ich habe jetzt auch nicht die Zeit, wie die ganzen Cartridges

        00:25:08.173 --> 00:25:12.913
        <v Holger Krupp>an meine... Muss ich das dann in beide Konsolen reinlegen? Ja, selbstverständlich.

        00:25:13.113 --> 00:25:14.153
        <v Arne ‚codenaga’ Ruddat>Die regeln ja nicht miteinander. danach.

        00:25:15.313 --> 00:25:16.613
        <v Holger Krupp>Das ist doch scheiße.

        00:25:20.173 --> 00:25:24.093
        <v Holger Krupp>Ja. Kann man den wenigsten, wenn man in der Versus 2 Spiele reinlegt,

        00:25:24.133 --> 00:25:25.333
        <v Holger Krupp>kann man die so doppelt da rein?

        00:25:25.433 --> 00:25:29.973
        <v Arne ‚codenaga’ Ruddat>Ja, klar. Aber du musst die einzeln reinlegen, weil der will die Updates einzeln machen.

        00:25:30.733 --> 00:25:33.433
        <v Arne ‚codenaga’ Ruddat>Und der startet auch jedes Mal bei einem Update die Konsole neu.

        00:25:34.973 --> 00:25:35.693
        <v Holger Krupp>Oh, okay.

        00:25:36.633 --> 00:25:37.893
        <v Arne ‚codenaga’ Ruddat>Bei mir hat es tatsächlich bei der,

        00:25:39.953 --> 00:25:43.053
        <v Arne ‚codenaga’ Ruddat>Technos Arcade 1, da hat das Update bei mir nicht funktioniert.

        00:25:43.193 --> 00:25:46.913
        <v Arne ‚codenaga’ Ruddat>Keine Ahnung warum. Ich versuche es einfach mit dem nächsten Software-Update der Konsolen nochmal.

        00:25:47.473 --> 00:25:51.493
        <v Holger Krupp>Keine Ahnung. Also ich updatee diese Cartridges, wenn ich sie dann irgendwann

        00:25:51.493 --> 00:25:55.153
        <v Holger Krupp>mal zufällig reinlege. Und wenn dann ein Update ist, dann lege ich sie rein.

        00:25:55.313 --> 00:25:59.573
        <v Arne ‚codenaga’ Ruddat>Genau, das habe ich halt auch gemacht. Aber ich habe halt jetzt ein paar davon

        00:25:59.573 --> 00:26:01.233
        <v Arne ‚codenaga’ Ruddat>reingelegt und gedacht, ja, warum nicht.

        00:26:03.473 --> 00:26:06.173
        <v Arne ‚codenaga’ Ruddat>Ich finde es jedenfalls ganz schön und es ist halt übersichtlich und man kann

        00:26:06.173 --> 00:26:11.513
        <v Arne ‚codenaga’ Ruddat>sich das auch so als Cartridge-Hüllen-Rückseiten- Wand angucken.

        00:26:11.753 --> 00:26:14.113
        <v Arne ‚codenaga’ Ruddat>Und auch das ist ziemlich übersichtlich, weil man man dann genau sieht,

        00:26:14.213 --> 00:26:19.673
        <v Arne ‚codenaga’ Ruddat>wann die erschienen sind und welche man schon hat. So, jedenfalls.

        00:26:21.593 --> 00:26:24.713
        <v Arne ‚codenaga’ Ruddat>Ja, ansonsten, ich habe gestern eine neue Podcast-Folge veröffentlicht,

        00:26:24.753 --> 00:26:27.533
        <v Arne ‚codenaga’ Ruddat>nachdem wir letzte Woche vier unter Deck ausfallen lassen mussten,

        00:26:27.553 --> 00:26:28.973
        <v Arne ‚codenaga’ Ruddat>weil wir einfach keinen Termin gefunden haben.

        00:26:29.833 --> 00:26:33.433
        <v Arne ‚codenaga’ Ruddat>Nicht so schlimm, wir sind ja auch gerade zwischen Staffel 3 und vor Staffel

        00:26:33.433 --> 00:26:37.953
        <v Arne ‚codenaga’ Ruddat>4, also nach Staffel 3, vor Staffel 4, so, habe ich gestern eine neue Folge

        00:26:37.953 --> 00:26:40.013
        <v Arne ‚codenaga’ Ruddat>von offenbar The Orville veröffentlicht.

        00:26:40.053 --> 00:26:43.773
        <v Arne ‚codenaga’ Ruddat>Die Folgen sind inzwischen, also also die Serienepisoden, sind über eine Stunde

        00:26:43.773 --> 00:26:47.333
        <v Arne ‚codenaga’ Ruddat>lang, deswegen teilen wir die in zwei Teile und jetzt haben wir den ersten Teil,

        00:26:47.973 --> 00:26:52.953
        <v Arne ‚codenaga’ Ruddat>der Episode zweimal im Leben, das ist die sechste der dritten Staffel von The Orville,

        00:26:54.073 --> 00:26:58.333
        <v Arne ‚codenaga’ Ruddat>besprochen und veröffentlicht und, ja, war gut. Machen wir wieder.

        00:26:59.833 --> 00:27:05.793
        <v Holger Krupp>Tja, ich habe letztens, ich weiß gar nicht mehr warum, aber ich habe irgendwie

        00:27:05.793 --> 00:27:10.533
        <v Holger Krupp>App Store ein bisschen rumgesucht nach Spielen und habe dort festgestellt,

        00:27:10.533 --> 00:27:14.253
        <v Holger Krupp>dass viele Spiele, die eigentlich ganz cool sind,

        00:27:15.273 --> 00:27:16.913
        <v Holger Krupp>inzwischen bei Netflix sind.

        00:27:17.073 --> 00:27:23.093
        <v Holger Krupp>Da bekommst du zum Beispiel Turtle Shredders Revenge oder World of Goo oder sowas.

        00:27:24.339 --> 00:27:28.099
        <v Holger Krupp>in deinem Netflix-Abo mit dabei. Und das fand ich ganz cool.

        00:27:28.199 --> 00:27:32.079
        <v Holger Krupp>Also ich weiß gar nicht, ob du... Oder auch Shovel Knight, Pocket Dungeon und sowas.

        00:27:32.159 --> 00:27:36.919
        <v Holger Krupp>Also nicht nur irgendwelche blöden Spiele, sondern Spiele, die eigentlich cool

        00:27:36.919 --> 00:27:41.119
        <v Holger Krupp>sind, wo dann halt keine extra Kosten anfallen. Die hat im Netflix-Abo mit drin.

        00:27:41.159 --> 00:27:48.119
        <v Holger Krupp>Und man meldet sich dann mit seiner Netflix-ID dann in dem Spiel an und kann

        00:27:48.119 --> 00:27:50.019
        <v Holger Krupp>dann Spiele spielen. Und das fand ich ganz lustig.

        00:27:50.239 --> 00:27:53.219
        <v Holger Krupp>Oder interessant, weil da halt echt coole Sachen dabei sind.

        00:27:53.219 --> 00:27:55.279
        <v Holger Krupp>Benutzt du diese Netflix-Spiele?

        00:27:56.139 --> 00:27:56.799
        <v Holger Krupp>Wusstest du davon?

        00:27:57.139 --> 00:27:57.539
        <v Arne ‚codenaga’ Ruddat>Ja, sicher.

        00:27:58.459 --> 00:28:01.919
        <v Holger Krupp>Dass die existieren. Hast du auch nicht reingeguckt, was dazu gehört?

        00:28:02.159 --> 00:28:06.039
        <v Holger Krupp>Man hätte ja vermutet, dass da einfach nur Schrott-Spiele zu Serien drin sind.

        00:28:06.279 --> 00:28:08.939
        <v Arne ‚codenaga’ Ruddat>Nee, überhaupt nicht. Ich hab schon gewusst, dass da brauchbares Zeug drin ist.

        00:28:09.019 --> 00:28:10.759
        <v Arne ‚codenaga’ Ruddat>Ich hab nur gar keine Ahnung, wie ich damit umgehen soll.

        00:28:10.859 --> 00:28:14.759
        <v Arne ‚codenaga’ Ruddat>Und brauch auch gar nicht mehr Spiele in meinem Leben, als die, die ich mir aussuche.

        00:28:15.859 --> 00:28:18.179
        <v Arne ‚codenaga’ Ruddat>So ein Spiele-Abo hab ich ja auch sonst nirgendwo.

        00:28:18.839 --> 00:28:24.399
        <v Holger Krupp>Ja, aber das sind so ... Hades ist da drin, Death Door. Also, das ist ein Dead Cell.

        00:28:24.899 --> 00:28:25.419
        <v Arne ‚codenaga’ Ruddat>Habe ich.

        00:28:26.119 --> 00:28:27.119
        <v Holger Krupp>Ja, ist ja egal.

        00:28:27.299 --> 00:28:29.219
        <v Arne ‚codenaga’ Ruddat>Außerdem kann ich mir auch gar nicht vorstellen, wie ich die spielen soll.

        00:28:29.379 --> 00:28:31.919
        <v Arne ‚codenaga’ Ruddat>Also, Netflix ist für mich so ein Telefon- und Fernsehding.

        00:28:31.919 --> 00:28:32.499
        <v Holger Krupp>Auf dem Telefon?

        00:28:32.899 --> 00:28:35.219
        <v Arne ‚codenaga’ Ruddat>Ja, ich spiele doch keine Spiele auf dem Telefon. Wer bin ich denn?

        00:28:35.479 --> 00:28:37.719
        <v Arne ‚codenaga’ Ruddat>Wofür habe ich denn eine ganze Staffel Konsolen rumliegen?

        00:28:37.979 --> 00:28:40.019
        <v Holger Krupp>Wenn du im Bus sitzt.

        00:28:40.519 --> 00:28:44.439
        <v Arne ‚codenaga’ Ruddat>Nee, wenn ich im Bus sitze, dann packe ich mein Palm Island oder mein Palm Laboratory

        00:28:44.439 --> 00:28:47.099
        <v Arne ‚codenaga’ Ruddat>aus. Oder ich spiele was auf Boardgame Arena.

        00:28:47.899 --> 00:28:50.979
        <v Arne ‚codenaga’ Ruddat>Nein, nein, nein. Nein, soweit kommt es noch, dass ich irgendwelche Action-Spiele

        00:28:50.979 --> 00:28:54.199
        <v Arne ‚codenaga’ Ruddat>auf dem Telefon spiele. Mit der fusseligen Touch-Steuerung.

        00:28:54.239 --> 00:28:58.519
        <v Holger Krupp>Nein, so Puzzle-Spiele, sowas wie Cut the Rope und sowas.

        00:28:58.659 --> 00:29:00.699
        <v Arne ‚codenaga’ Ruddat>Ja, Puzzle-Spiele, sowas wie Hades und...

        00:29:01.599 --> 00:29:02.819
        <v Holger Krupp>Oder Cut the Rope.

        00:29:03.759 --> 00:29:06.939
        <v Arne ‚codenaga’ Ruddat>Nein, nein, nein, auf keinen Fall. Da bin ich nicht der Typ für.

        00:29:07.019 --> 00:29:09.639
        <v Arne ‚codenaga’ Ruddat>Handy-Spiele, das Einzige, was ich tatsächlich auf dem Handy spiele,

        00:29:09.659 --> 00:29:14.159
        <v Arne ‚codenaga’ Ruddat>ist wie gesagt irgendwie Boardgame-Arena über Internet irgendwie Brettspiele und Pokémon Go.

        00:29:15.139 --> 00:29:15.939
        <v Holger Krupp>Exploding Kittings.

        00:29:16.079 --> 00:29:19.159
        <v Arne ‚codenaga’ Ruddat>Nee, nein, das mag ich Ja, nicht mal als echtes Spiel.

        00:29:20.979 --> 00:29:23.419
        <v Arne ‚codenaga’ Ruddat>Also für mich ist es nicht. Ich freue mich, dass es Leute gibt,

        00:29:23.499 --> 00:29:26.239
        <v Arne ‚codenaga’ Ruddat>die das irgendwie gut finden und da gerne irgendwie mit Netflix noch irgendwie

        00:29:26.239 --> 00:29:30.159
        <v Arne ‚codenaga’ Ruddat>ein paar Spiele zu kriegen und so. Keine Ahnung, was Netflix sich dabei gedacht hat.

        00:29:30.659 --> 00:29:33.819
        <v Holger Krupp>Ich weiß auch nicht, wie das in das Netflix-Portfolio reinpasst,

        00:29:33.879 --> 00:29:35.419
        <v Holger Krupp>aber es sind coole Sachen dabei.

        00:29:35.619 --> 00:29:37.619
        <v Arne ‚codenaga’ Ruddat>Vielleicht haben sie sich gedacht, hm, wir brauchen auch irgendwas,

        00:29:37.759 --> 00:29:40.719
        <v Arne ‚codenaga’ Ruddat>um die Leute bei der Stange zu halten, wenn unser Dienst immer,

        00:29:40.819 --> 00:29:42.039
        <v Arne ‚codenaga’ Ruddat>immer, immer teurer wird.

        00:29:43.299 --> 00:29:44.399
        <v Holger Krupp>The Queen's Gambit.

        00:29:45.819 --> 00:29:48.939
        <v Arne ‚codenaga’ Ruddat>Ja. Ja. Naja, ist halt nicht für mich.

        00:29:52.059 --> 00:29:56.739
        <v Holger Krupp>Guti. Dann würde ich sagen, mehr haben wir nicht, ne?

        00:29:56.839 --> 00:29:57.499
        <v Arne ‚codenaga’ Ruddat>Mehr haben wir nicht.

        00:29:58.159 --> 00:30:01.619
        <v Holger Krupp>Nächste Woche gucken wir James Bond, denk dran, Live and Let Die.

        00:30:01.939 --> 00:30:02.459
        <v Arne ‚codenaga’ Ruddat>Ganz genau.

        00:30:03.539 --> 00:30:05.379
        <v Holger Krupp>Und dann bis zum nächsten Mal.

        00:30:05.519 --> 00:30:06.839
        <v Arne ‚codenaga’ Ruddat>Ja, dann feier schön. Bis denn.

        00:30:06.919 --> 00:30:07.259
        <v Holger Krupp>Tschüss.
        """
    
    TranscriptListView(vttContent: WaitingForReviewText)
}
