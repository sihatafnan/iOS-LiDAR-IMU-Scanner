//
//  SessionList.swift
//  Stray Scanner
//
//  Created by Kenneth Blomqvist on 11/15/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//

import SwiftUI
import CoreData

class SessionListViewModel: ObservableObject {
    private var dataContext: NSManagedObjectContext?
    @Published var sessions: [Recording] = []
    @Published var sessionCount: Int = 0 // New property for in-memory count

    init() {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        dataContext = appDelegate.persistentContainer.viewContext
        self.sessions = []
        sessionCount = 0 // Reset count on initialization
        NotificationCenter.default.addObserver(self, selector: #selector(sessionsChanged), name: NSNotification.Name("sessionsChanged"), object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func fetchSessions() {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Recording")
        do {
            let fetched: [NSManagedObject] = try dataContext?.fetch(request) ?? []
            sessions = fetched.map { session in
                return session as! Recording
            }
//            sessionCount = 0 // Reset the count when fetching sessions
        } catch let error as NSError {
            print("Something went wrong. Error: \(error), \(error.userInfo)")
        }
    }

    @objc func sessionsChanged() {
        fetchSessions()
        sessionCount += 1
    }

}

struct SessionList: View {
    @ObservedObject var viewModel = SessionListViewModel()
    @State private var showingInfo = false
    @State private var autoNavigate = false // Add a flag for automatic navigation
    

    init() {
        UITableView.appearance().backgroundColor = UIColor(named: "BackgroundColor")
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            NavigationView {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Recordings")
                            .foregroundColor(Color("TextColor"))
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)
                            .padding([.top, .leading], 15.0)
                        Spacer()
                        Button(action: {
                            showingInfo.toggle()
                        }, label: {
                            Image(systemName: "info.circle")
                                .resizable()
                                .frame(width: 25, height: 25, alignment: .center)
                                .padding(.top, 17)
                                .padding(.trailing, 20)
                                .foregroundColor(Color("TextColor"))
                        }).sheet(isPresented: $showingInfo) {
                            InformationView()
                        }
                    }

                    if !viewModel.sessions.isEmpty {
                        Text("Total Recordings in Current Session: \(viewModel.sessionCount)")
                            .foregroundColor(Color("TextColor"))
                            .font(.body)
                            .fontWeight(.medium)
                            .padding([.leading, .top], 15.0)
                    }

                    if !viewModel.sessions.isEmpty {
                        List {
                            ForEach(Array(viewModel.sessions.enumerated()), id: \.element) { i, recording in
                                NavigationLink(destination: SessionDetailView(recording: recording)) {
                                    SessionRow(session: recording)
                                }
                            }
                        }
                        Spacer()
                    } else {
                        Spacer()
                        Text("No recorded sessions. Record one, and it will appear here.")
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 50.0)
                    }
                    HStack {
                        Spacer()
                        NavigationLink(destination: NewSessionView(), isActive: $autoNavigate) { // Trigger navigation programmatically
                            Text("Record new session")
                                .font(.title3)
                                .padding(20)
                                .background(Color("TextColor"))
                                .foregroundColor(Color("LightColor"))
                                .cornerRadius(35)
                                .padding(20)
                        }
                        Spacer()
                    }
                    if (viewModel.sessions.isEmpty) {
                        Spacer()
                    }
                }
                .navigationBarHidden(true)
                .background(Color("BackgroundColor").ignoresSafeArea())
                .onAppear {
                    DispatchQueue.main.async {
                        viewModel.fetchSessions()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            autoNavigate = true // Trigger navigation to the recording screen
                        }
                    }
                }
            }
            .background(Color("BackgroundColor").edgesIgnoringSafeArea(.all))
        }
    }
}


struct SessionList_Previews: PreviewProvider {
    static var previews: some View {
        SessionList()
    }
}
