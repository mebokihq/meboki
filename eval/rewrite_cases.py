"""Rewrite-detection cases (2026-11-16). Inputs only; labels come from rewrite_report.py's rubric review.
LOCAL: many small independent fixes (inline is right). AWKWARD: non-native / run-on / clumsy text where a
model tends to rewrite (a rewrite card is right). Short single fixes are in dataset.ERR already."""

LOCAL = [
    "Hi team, i wanted to give a quick update on the migration. We was able to move most of the services last week, but their is still a few issues with the payment service.",
    "The logs shows timeouts when the database are under load. I think we should of tested this more carefully before.",
    "Lets discuss it on tomorrow's call, and please send me any informations you have.",
    "Thanks for you're help yesterday, it was realy usefull and i appreciate it alot.",
    "She dont like apples, but he likes them alot and eat one every day.",
    "Their going to the park tomorow, and then there going to get ice cream.",
    "I recieved you're email and will adress the isue as soon as posible.",
    "We have to complete the report untill friday, otherwise the client will not be happy.",
    "Me and him went to the store, buyed some milk, and then we goes home.",
    "The meeting have been moved to 3pm becuase the manager are travelling.",
    "Please find attached the documents you requested, let me know if you needs anything else.",
    "I has been working on this project since three month and it is allmost finished.",
    "Its a good idea but we should consider the cost, the timeline and who will do it?",
    "He said that he dont know nothing about the incident, and I beleive him.",
    "Every employees must wear there badge at all times while in the building.",
    "Could you please sent me the invoice for last months order, i cant find it.",
    "The software update have fixed most of the bugs but their are still some crashes on startup.",
    "I am agree with your proposal, however I think we need more datas before deciding.",
    "We discused the problem for hours and finaly came to a conclusion that satisfy everyone.",
    "My freind and me is planning a trip to Itally next summer, we hopes it will be fun.",
    "Yesterday I go to the doctor and he tell me to rest for a week.",
    "There is many reason why the project failed, most important are the lack of planing.",
    "Dear Mr. Smith, I am writting to inform you that you're application has been recieved.",
    "The new feature allow users to export they're data in different format.",
    "if you have any question, please dont hesitate to contact us.",
]

AWKWARD = [
    "I am writing for to ask you about the possibility of the meeting in which we could discuss about the project what we started before.",
    "Yesterday I was going to the shop for buy some food but it was closed because of is holiday so I returned home with empty hands.",
    "The company which I am working there is very big and have many peoples who are doing different things in different departments.",
    "Because of the reason that the weather was bad, we decided that the picnic that we planned it will be moved to another day.",
    "My opinion about this theme is that it is very important for the society because nowadays the technologies are developing very fast.",
    "I want that you send me the report until tomorrow because my boss he is waiting it already since two days.",
    "In the last time I have much thought about the changing of my job, but I am not sure that is it the right decision for me.",
    "He is a person who he always is helping other persons when they have problems with their works.",
    "Please be so kind and tell me what is the status of my request which I have sent you in the last week.",
    "We are glad to inform you that your application for the vacancy was accepted and we are waiting you on the interview.",
    "The product what we are selling it is of very high quality and the price is also is very reasonable for everyone peoples.",
    "After I have finished to read the book, I understood that the author wanted to tell us about the importance from family.",
    "Our team have decided to postponing the release because there is some problems what we need to fix them before.",
    "It is depend on many factors that how much time the project will take and what is the budget what we have.",
    "I am very interesting in this position because I have a big experience in the field and I like very much to working with peoples.",
    "She told me that she cannot to come to the party because of she has a lot of the works to do in the home.",
    "With regards to your email of yesterday, I would like to say that I am agree in principle but there is things which need to be clarified before.",
    "The reason why I am late is because that my car it was broken and I was need to wait the mechanic during two hours.",
    "Despite of the fact that he was tired, but he continued to working until the very late in the night.",
    "Could you explain me how this function it works, because I try to understand it but the documentation is not clear for me.",
    "This is the thing that I wanted to say to you about it that we should be doing more better with the communication between the teams.",
    "Our customers are complaining about that the app is slow, so we need to do something with this for improve the speed.",
    "At the end of the day what matters is that the user is able for to complete his task without any frustrations of the interface.",
    "I think that, that the proposal what you made is good, but need to be think about the risks more deeper.",
    "Me and my colleague we was discussing about the plan which was made from the manager and we thinked that it have some weakness.",
]

# Harsh: broken enough that the model has to restructure (word order, clause rebuild).
HARSH = [
    "Me and my colleague we was discussing about the plan which was made from the manager and we thinked that it have some weakness.",
    "Yesterday me and friend go cinema but film was very boring so we leaved after half hour and go eat pizza.",
    "Is very difficult for me explain you what happened because I not remember good all things that was happen in that day.",
    "I am student of university since two years and I am study the computer science what is very interesting for me.",
    "Why you not answered to my letter that I sended you before one week? I am waiting still the answer from you.",
    "He asked me that where I am living and what I am doing in this city and I answered him that I am here for the work.",
    "If I would have more money I would bought the house which have big garden and many tree for my children playing.",
    "The meeting what we was planned for monday it is cancelled because of the boss he is sick and nobody can to replace him.",
    "We needs discuss about budget for next year, because actual situation is not good and costs are more high than before expected.",
    "Thank you for your fast answer, I will be waiting you tomorrow in the office on 10 o'clock for to sign the contract together.",
    "She is working in this company from five years, but she not never got a promotion, and she thinking to leave.",
    "Hello, I am looking for the job what I can do from the home, because I have small baby and I cannot go to the office every day.",
]

# My judgement of which model replies read better as ONE rewrite (the changes depend on each other: tense
# and word order rebuilt around the mistake). Everything else in LOCAL / AWKWARD / HARSH and all of
# dataset.ERR must stay separate fixes. Judged on the replies in results_rewrite_e4b.json.
EXPECT_REWRITE = {
    "If I would have more money I would bought the house which have big garden and many tree for my children playing.",
    "Yesterday me and friend go cinema but film was very boring so we leaved after half hour and go eat pizza.",
    "Is very difficult for me explain you what happened because I not remember good all things that was happen in that day.",
    "In the last time I have much thought about the changing of my job, but I am not sure that is it the right decision for me.",
    "Me and my colleague we was discussing about the plan which was made from the manager and we thinked that it have some weakness.",
}
