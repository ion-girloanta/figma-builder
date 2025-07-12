import React from 'react';
import ReactDOM from 'react-dom/client';
import { BrowserRouter as Router, Route, Routes } from 'react-router-dom';
import './index.css';

const Tickets = () => <div className="text-xl text-blue-600">Hello from /tickets</div>;

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <Router>
      <Routes>
        <Route path="/tickets" element={<Tickets />} />
      </Routes>
    </Router>
  </React.StrictMode>
);