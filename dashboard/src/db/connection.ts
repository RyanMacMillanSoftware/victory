import mysql from 'mysql2/promise'

export const pool = mysql.createPool({
  host: '127.0.0.1',
  port: 3307,
  user: 'root',
  password: '',
  waitForConnections: true,
  connectionLimit: 5,
  queueLimit: 0,
  timezone: '+00:00',
  typeCast(field, next) {
    // Return DATE/DATETIME as ISO strings rather than JS Date objects
    if (field.type === 'DATE' || field.type === 'DATETIME' || field.type === 'TIMESTAMP') {
      return field.string() ?? null
    }
    return next()
  },
})
